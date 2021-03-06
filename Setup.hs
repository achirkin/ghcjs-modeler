{-# OPTIONS_GHC -Wall #-}
module Main (main) where

import Control.Monad (when, unless, join, forM_, (>=>))
import Distribution.PackageDescription
import Distribution.Simple
import Distribution.Simple.Setup
import Distribution.Simple.LocalBuildInfo
import System.Directory
import System.FilePath
import System.IO


main :: IO ()
main = defaultMainWithHooks simpleUserHooks
         { preBuild = addBuildEnvHook
         , postBuild = \args bf pd lbi -> do
             postBuild simpleUserHooks args bf pd lbi
             mapM_ (`postBuildHooks` lbi) args
         }

postBuildHooks :: String -> LocalBuildInfo -> IO ()
postBuildHooks "exe:qua-view" lbi = do
    wrapCodeHook lbi
    aggregateCssHook lbi
    copyOutputHook "qua-view" "qua-view" "css" lbi
    copyOutputHook "qua-view" "qua-view" "js" lbi
postBuildHooks "exe:qua-worker-loadgeometry" lbi =
    copyOutputHook "qua-worker-loadgeometry" "all" "js" lbi
postBuildHooks "lib:qua-view" _ = return () -- ignore library component
postBuildHooks "test:geojson-tests" _ = return () -- ignore test component
postBuildHooks as _ =
    putStrLn $  "Warning: ignoring postbuild argument: " ++ show as


-- | It's just a simple way to get the main executable name.
myExeName :: String
myExeName = "qua-view"

-- | Here is the place where we store
makeCssGenPath :: FilePath -> FilePath
makeCssGenPath buildD = buildD </> myExeName </> (myExeName ++ "-tmp") </> "CssGen"

-- | Where all generated js code is stored
makeExeDir :: String -> FilePath -> FilePath
makeExeDir cname buildD = buildD </> cname </> (cname ++ ".jsexe")

-- | A path to a special file.
--   This file contains a list of modules using TH unique identifiers.
--   That is, it keeps short unique ids for each module that needs them.
makeModulesUniquePath :: FilePath -> FilePath
makeModulesUniquePath buildD = buildD </> myExeName </> (myExeName ++ "-tmp") </> "modules.unique"

-- | Wrapp all JS code into a single function that runs after the page is loaded.
wrapCodeHook :: LocalBuildInfo -> IO ()
wrapCodeHook lbi = readFile exeFile >>= \content -> writeFile exeFile' $ unlines
    [ "var global = this;"
    , "function h$runQuaView(){"
    , "\"use strict\""
    , content
    , "}"
    , "if (document.readyState === 'complete')"
    , "{ h$runQuaView.bind(global)(); }"
    , "else { window.onload = h$runQuaView.bind(global); }"
    ]
  where
    exeDir =  makeExeDir myExeName $ buildDir lbi
    exeFile = exeDir </> "all.js"
    exeFile' = exeDir </> myExeName <.> "js"


-- | Copy generated files to web folder
--   If we have the qua-sever folder near the qua-view folder (i.e. in the qua-kit repo),
--   then copy generate javascript and css files there.
copyOutputHook :: String -> String -> String -> LocalBuildInfo -> IO ()
copyOutputHook compName origName ext lbi = do
    doesDirectoryExist webPath >>= \e -> when e $
      copyFile fname  (webPath </> compName <.> ext)
    doesDirectoryExist quaServerPath >>= \e -> when e $
      copyFile fname  (quaServerPath </> ext </> compName <.> ext)
  where
    webPath = "web"
    quaServerPath = ".." </> "qua-server" </> "static"
    fname = makeExeDir compName (buildDir lbi) </> origName <.> ext


-- | Get all files from CssGen folder and put their content into a single css file qua-view.css
aggregateCssHook :: LocalBuildInfo -> IO ()
aggregateCssHook lbi = do
    buildPrefix <- canonicalizePath (buildDir lbi) >>= makeAbsolute
    let cssGenDir = makeCssGenPath buildPrefix
        exeDir    = makeExeDir myExeName buildPrefix
        cssFile   = exeDir </> myExeName <.> "css"
        filterExistingCss fname = do
            let fpath = cssGenDir </> fname
            exists <- doesFileExist fpath
            return [fpath | exists]
    createDirectoryIfMissing True cssGenDir
    createDirectoryIfMissing True exeDir
    -- get list of css files to aggregate
    cssFiles <- listDirectory cssGenDir >>= fmap join . mapM filterExistingCss
    -- remove final css result file if exists
    doesFileExist cssFile >>= flip when (removeFile cssFile)
    -- finally write content of all css files into the new one
    withFile cssFile WriteMode $ \h -> forM_ cssFiles (readFile >=> hPutStrLn h)


-- | This function is executed before building the project.
--   Its purpose is to prepare CPP variables containing project's build folder and special files,
--   and also create them if necessary.
addBuildEnvHook :: Args -> BuildFlags -> IO HookedBuildInfo
addBuildEnvHook _ bf = do
    buildPrefix <- (>>= makeAbsolute)
                                . canonicalizePath
                                . ( </> "build")
                                . fromFlagOrDefault (error "Setup.hs/PreBuildHook: no build prefix specified!")
                                $ buildDistPref bf
    let cssGenPath    = makeCssGenPath buildPrefix
        modulesUnique = makeModulesUniquePath buildPrefix
    createDirectoryIfMissing True cssGenPath
    doesFileExist modulesUnique >>= flip unless (writeFile modulesUnique "")
    return ( Nothing
           , [( myExeName
              , emptyBuildInfo { cppOptions = [ "-DCSS_GEN_PATH=" ++ show cssGenPath
                                              , "-DMODULES_UNIQUE_PATH=" ++ show modulesUnique
                                              ]}
              )]
           )

