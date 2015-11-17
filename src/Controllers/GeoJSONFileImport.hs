{-# LANGUAGE JavaScriptFFI #-}
{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Controllers.GeoJSONFileImport
-- Copyright   :  (c) Artem Chirkin
-- License     :  BSD3
--
-- Maintainer  :  Artem Chirkin <chirkin@arch.ethz.ch>
-- Stability   :  experimental
--
--
--
-----------------------------------------------------------------------------

module Controllers.GeoJSONFileImport
    ( onGeoJSONFileImport
    , loadGeoJSONFromLink
    ) where


import Data.Geometry.Structure.Feature (FeatureCollection)
import Data.JSArray (asJSVal)
import GHCJS.Types
--import GHCJS.Marshal
import GHCJS.Foreign.Callback
import GHCJS.Foreign (isTruthy)

import GHCJS.Useful
import Controllers.GUIEvents
import Data.Coerce (coerce)

onGeoJSONFileImport :: JSElement -> GeoJSONLoadCallBack -> IO ()
onGeoJSONFileImport importButton callback = elementOnChange importButton $ do
    programInProgress
    logText "Trying to parse GeoJSON FeatureCollection..."
    gfc <- coerce <$> getElementFiles importButton
    isBehChecked <- isElementChecked  "dynamicstaticswitcher"
    logText "GeoJSON FeatureCollection is imported."
    callback GeoJSONLoaded
        { isDynamic          = isBehChecked
        , featureCollection  = gfc
        }
--    c <- getElementFiles importButton >>= fromJSRef_aeson
--    case c of
--        Nothing -> logText "Could not read geometry"
--        Just gfc -> do
--            isBehChecked <- isElementChecked  "dynamicstaticswitcher"
--            logText "GeoJSON FeatureCollection is imported."
--            callback GeoJSONLoaded
--                { isDynamic          = isBehChecked
--                , featureCollection  = gfc
--                }
    programIdle

loadGeoJSONFromLink :: JSString -> Bool -> GeoJSONLoadCallBack -> IO ()
loadGeoJSONFromLink url isDyn callback = do
    c <- getUrlJSON url
    if not (isTruthy $ asJSVal c)
    then logText "Could not read geometry"
    else callback GeoJSONLoaded
          { isDynamic         = isDyn
          , featureCollection = c
          }


foreign import javascript unsafe "$r = document.getElementById($1).checked;"
    isElementChecked :: JSString -> IO Bool

-- | If checkbox element is checked
foreign import javascript interruptible "var r = new FileReader(); \
    \ var load = function() { \
    \ if (r.readyState != FileReader.EMPTY ) { \
    \   var json = null; \
    \   try { \
    \       json = JSON.parse(r.result); \
    \   } catch (err) { logText('Your browser does not like JSON file you have chosen: ' + err); } \
    \   $c(json); }}; \
    \ var errfun = function() {logText('Your browser cannot open file.'); $c(null);}; \
    \ r.onloadend = load;  \
    \ r.onerror = errfun; \
    \ r.readAsText($1.files[0]);"
    getElementFiles :: JSElement -> IO FeatureCollection


foreign import javascript interruptible "var xmlHttp = new XMLHttpRequest(); \
    \ var json = null; \
    \ var i = 0;\
    \ var loadjson = function() { \
    \   try { \
    \       json = JSON.parse(xmlHttp.responseText); \
    \   } catch (err) { logText('Your browser does not like JSON file you have chosen: ' + err); } \
    \   if(i == 0){i++;$c(json);} \
    \ }; \
    \ var errjson = function() {logText('Your browser cannot execute http request on ' + $1); if(i == 0){i++;$c(null);} }; \
    \ try { \
    \     xmlHttp.onload = loadjson; \
    \     xmlHttp.onerror = errjson; \
    \     xmlHttp.open( 'GET', $1, true ); \
    \     xmlHttp.send( ); \
    \ } catch (err) { logText(err); if(i == 0){i++;$c(null);}} "
    getUrlJSON :: JSString -> IO FeatureCollection


-- | Simple event when JSElement is changed (e.g. one picked file in "file" button)
elementOnChange :: JSElement -> IO () -> IO ()
elementOnChange element clickFun = do
    clickCallBack <- asyncCallback clickFun
    elementOnChange' element clickCallBack
foreign import javascript unsafe "\
    \ $1.addEventListener('change', function(event){ \
    \     var e = window.event || event; \
    \     e.preventDefault(); \
    \     e.stopPropagation(); \
    \     $2(); \
    \     return false; \
    \ });"
    elementOnChange' :: JSElement -> Callback (IO ()) -> IO ()
