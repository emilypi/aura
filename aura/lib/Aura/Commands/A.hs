{-# LANGUAGE FlexibleContexts, TypeApplications, MonoLocalBinds #-}
{-# LANGUAGE ViewPatterns, MultiWayIf, OverloadedStrings #-}

-- | Handles all `-A` operations

{-

Copyright 2012 - 2018 Colin Woodbury <colin@fosskers.ca>

This file is part of Aura.

Aura is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Aura is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Aura.  If not, see <http://www.gnu.org/licenses/>.

-}

module Aura.Commands.A
  ( install
  , upgradeAURPkgs
  , aurPkgInfo
  , aurPkgSearch
  , displayPkgDeps
  , downloadTarballs
  , displayPkgbuild
  , aurJson
 ) where

import           Aura.Colour
import           Aura.Core
import qualified Aura.Install as I
import           Aura.Languages
import           Aura.Packages.AUR
import           Aura.Packages.Repository (pacmanRepo)
import           Aura.Pkgbuild.Fetch
import           Aura.Settings
import           Aura.State (saveState)
import           Aura.Types
import           Aura.Utils
import           BasePrelude hiding ((<+>))
import           Control.Monad.Freer
import           Control.Monad.Freer.Error
import           Control.Monad.Freer.Reader
import           Data.Aeson.Encode.Pretty (encodePrettyToTextBuilder)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Text.Lazy (toStrict)
import           Data.Text.Lazy.Builder (toLazyText)
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Versions
import           Linux.Arch.Aur
import           Shelly (whenM, pwd, shelly, toTextIgnore)

---

installOptions :: I.InstallOptions
installOptions = I.InstallOptions { I.label         = "AUR"
                                  , I.installLookup = aurLookup
                                  , I.repository    = pacmanRepo <> aurRepo }

install :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) => S.Set T.Text -> Eff r ()
install = I.install installOptions

upgradeAURPkgs :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) => S.Set T.Text -> Eff r ()
upgradeAURPkgs pkgs = do
  ss <- ask
  let !ignores     = map Just . toList . ignoredPkgsOf $ commonConfigOf ss
      notIgnored p = fmap fst (splitNameAndVer p) `notElem` ignores
      lang         = langOf ss
  send . notify ss $ upgradeAURPkgs_1 lang
  foreignPkgs <- S.filter (notIgnored . _spName) <$> send foreignPackages
  toUpgrade   <- possibleUpdates foreignPkgs
  auraFirst   <- auraCheck $ map (aurNameOf . fst) toUpgrade
  if | auraFirst -> auraUpgrade
     | otherwise -> do
         devel <- develPkgCheck
         send . notify ss $ upgradeAURPkgs_2 lang
         if | null toUpgrade && null devel -> send . warn ss $ upgradeAURPkgs_3 lang
            | otherwise -> reportPkgsToUpgrade toUpgrade (toList devel)
         unless (switch ss DryRun) saveState
         install $ S.fromList (map (aurNameOf . fst) toUpgrade) <> pkgs <> devel

possibleUpdates :: (Member (Reader Settings) r, Member IO r) => S.Set SimplePkg -> Eff r [(AurInfo, Versioning)]
possibleUpdates (toList -> pkgs) = do
  aurInfos <- aurInfo $ map _spName pkgs
  let !names  = map aurNameOf aurInfos
      aurPkgs = filter (\(SimplePkg n _) -> n `elem` names) pkgs
  pure . filter isntMostRecent . zip aurInfos $ map _spVersion aurPkgs

auraCheck :: (Member (Reader Settings) r, Member IO r) => [T.Text] -> Eff r Bool
auraCheck toUpgrade = if "aura" `elem` toUpgrade
                         then ask >>= \ss -> send (optionalPrompt ss auraCheck_1)
                         else pure False

auraUpgrade :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) => Eff r ()
auraUpgrade = install $ S.singleton "aura"

develPkgCheck :: (Member (Reader Settings) r, Member IO r) => Eff r (S.Set T.Text)
develPkgCheck = ask >>= \ss ->
  if switch ss RebuildDevel then send develPkgs else pure S.empty

aurPkgInfo :: (Member (Reader Settings) r, Member IO r) => S.Set T.Text -> Eff r ()
aurPkgInfo = aurInfo . toList >=> traverse_ displayAurPkgInfo

displayAurPkgInfo :: (Member (Reader Settings) r, Member IO r) => AurInfo -> Eff r ()
displayAurPkgInfo ai = ask >>= \ss -> send . T.putStrLn $ renderAurPkgInfo ss ai <> "\n"

renderAurPkgInfo :: Settings -> AurInfo -> T.Text
renderAurPkgInfo ss ai = dtot . colourCheck ss $ entrify ss fields entries
    where fields   = infoFields . langOf $ ss
          entries = [ magenta "aur"
                    , annotate bold . pretty $ aurNameOf ai
                    , pretty $ aurVersionOf ai
                    , outOfDateMsg (dateObsoleteOf ai) $ langOf ss
                    , orphanedMsg (aurMaintainerOf ai) $ langOf ss
                    , cyan . maybe "(null)" pretty $ urlOf ai
                    , pretty . pkgUrl $ aurNameOf ai
                    , pretty . T.unwords $ licenseOf ai
                    , pretty . T.unwords $ dependsOf ai
                    , pretty . T.unwords $ makeDepsOf ai
                    , yellow . pretty $ aurVotesOf ai
                    , yellow . pretty . T.pack . printf "%0.2f" $ popularityOf ai
                    , maybe "(null)" pretty $ aurDescriptionOf ai ]

aurPkgSearch :: (Member (Reader Settings) r, Member IO r) => T.Text -> Eff r ()
aurPkgSearch regex = do
  ss <- ask
  db <- S.map _spName <$> send foreignPackages
  let t = case truncationOf $ buildConfigOf ss of  -- Can't this go anywhere else?
            None   -> id
            Head n -> take n
            Tail n -> reverse . take n . reverse
  results <- fmap (\x -> (x, aurNameOf x `S.member` db)) . t
            <$> aurSearch regex
  send $ traverse_ (T.putStrLn . renderSearch ss regex) results

renderSearch :: Settings -> T.Text -> (AurInfo, Bool) -> T.Text
renderSearch ss r (i, e) = searchResult
    where searchResult = if switch ss LowVerbosity then sparseInfo else dtot $ colourCheck ss verboseInfo
          sparseInfo   = aurNameOf i
          verboseInfo  = repo <> n <+> v <+> "(" <> l <+> "|" <+> p <>
                         ")" <> (if e then annotate bold " [installed]" else "") <> "\n    " <> d
          repo = magenta "aur/"
          n = mconcat . intersperse (bCyan $ pretty r) . map (annotate bold . pretty) . T.splitOn r $ aurNameOf i
          d = maybe "(null)" pretty $ aurDescriptionOf i
          l = yellow . pretty $ aurVotesOf i  -- `l` for likes?
          p = yellow . pretty . T.pack . printf "%0.2f" $ popularityOf i
          v = case dateObsoleteOf i of
            Just _  -> red . pretty $ aurVersionOf i
            Nothing -> green . pretty $ aurVersionOf i

displayPkgDeps :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) => S.Set T.Text -> Eff r ()
displayPkgDeps = I.displayPkgDeps installOptions

downloadTarballs :: (Member (Reader Settings) r, Member IO r) => S.Set T.Text -> Eff r ()
downloadTarballs pkgs = do
  currDir <- T.unpack . toTextIgnore <$> send (shelly @IO pwd)
  traverse_ (downloadTBall currDir) pkgs
    where downloadTBall path pkg = whenM (isAurPackage pkg) $ do
            ss <- ask
            let manager = managerOf ss
                lang    = langOf ss
            send . notify ss $ downloadTarballs_1 pkg lang
            void . send $ sourceTarball manager path pkg

displayPkgbuild :: (Member (Reader Settings) r, Member IO r) => S.Set T.Text -> Eff r ()
displayPkgbuild ps = do
  man <- asks managerOf
  pbs <- catMaybes <$> traverse (send . pkgbuild @IO man . T.unpack) (toList ps)
  send . traverse_ T.putStrLn $ intersperse border pbs
  where border = "\n#========== NEXT PKGBUILD ==========#\n"

isntMostRecent :: (AurInfo, Versioning) -> Bool
isntMostRecent (ai, v) = trueVer > Just v
  where trueVer = either (const Nothing) Just . versioning $ aurVersionOf ai

aurJson :: (Member (Reader Settings) r, Member IO r) => S.Set T.Text -> Eff r ()
aurJson ps = do
  m <- asks managerOf
  infos <- send . info @IO m $ toList ps
  let json = map (toStrict . toLazyText . encodePrettyToTextBuilder) infos
  send $ traverse_ T.putStrLn json

------------
-- REPORTING
------------
reportPkgsToUpgrade :: (Member (Reader Settings) r, Member IO r) =>
  [(AurInfo, Versioning)] -> [T.Text] -> Eff r ()
reportPkgsToUpgrade ups devels = do
  ss <- ask
  send . notify ss . reportPkgsToUpgrade_1 $ langOf ss
  send $ putDoc (colourCheck ss . vcat $ map f ups' <> map g devels) >> T.putStrLn "\n"
  where ups'     = map (second prettyV) ups
        nLen     = maximum $ map (T.length . aurNameOf . fst) ups <> map T.length devels
        vLen     = maximum $ map (T.length . snd) ups'
        g = annotate (color Cyan) . pretty
        f (p, v) = hsep [ cyan . fill nLen . pretty $ aurNameOf p
                        , "::"
                        , yellow . fill vLen $ pretty v
                        , "->"
                        , green . pretty $ aurVersionOf p ]
