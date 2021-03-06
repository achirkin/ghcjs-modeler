{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Commons.Http
    ( httpGet
    , httpGetNow, httpGetNow'
    , httpGetNowOrOnUpdate
    , httpPut
    , httpPost
    ) where

import Foreign.JavaScript.TH
import GHCJS.DOM.Types hiding (Event, Text)
import JavaScript.JSON.Types.Internal as JSON
import JavaScript.JSON.Types.Instances
import Reflex.Dom

import Commons.Import
import Commons.NoReflexDom
import Control.Monad (join)
import Data.JSString (pack)
import Data.JSString.Text (textFromJSString, textToJSString)
import GHCJS.DOM.JSFFI.XMLHttpRequest (sendString)


instance IsXhrPayload JSString where
  sendXhrPayload = sendString

-- | HTTP GET upon `Event a`
httpGet :: forall t b m
         . ( FromJSON b, TriggerEvent t m, PerformEvent t m
           , HasJSContext (Performable m), MonadIO (Performable m)
           , Reflex t )
        => Event t JSString -> m (Event t (Either JSError b))
httpGet event = do
  (resultE, resultTrigger) <- newTriggerEvent
  performEvent_ $ flip doHttp resultTrigger . getReqConfig <$> event
  return resultE

-- | HTTP POST `ToJSON a` upon `Event a`
httpPost :: forall t a b m
        . ( ToJSON a, FromJSON b, TriggerEvent t m, PerformEvent t m
          , HasJSContext (Performable m), MonadIO (Performable m)
          , Reflex t )
         => Event t (JSString, a) -> m (Event t (Either JSError b))
httpPost event = do
  (resultE, t) <- newTriggerEvent
  performEvent_ $ flip doHttp t. uncurry postJsonReqConfig <$> event
  return resultE


-- | HTTP PUT `ToJSON a` upon `Event a`
httpPut :: forall t a b m
        . ( ToJSON a, FromJSON b, TriggerEvent t m, PerformEvent t m
          , HasJSContext (Performable m), MonadIO (Performable m)
          , Reflex t )
         => Event t (JSString, a) -> m (Event t (Either JSError b))
httpPut event = do
  (resultE, t) <- newTriggerEvent
  performEvent_ $ flip doHttp t. uncurry putJsonReqConfig <$> event
  return resultE


-- | HTTP GET immediately
httpGetNow :: forall t b m
            . ( FromJSON b, TriggerEvent t m
              , Reflex t, HasJSContext m, MonadJSM m )
           => JSString -> m (Event t (Either JSError b))
httpGetNow url = do
  (e, t) <- newTriggerEvent
  doHttp (getReqConfig url) t
  return e

httpGetNow' :: forall b m
             . ( FromJSON b, HasJSContext m, MonadJSM m )
            => JSString -> (Either JSError b -> IO ()) -> m ()
httpGetNow' url = doHttp (getReqConfig url)

-- | execute HTTP GET immediately if called with a Dynamic that currently
--   holds `Just url`, execute upon Dynamic change otherwise
httpGetNowOrOnUpdate :: forall t b m
                     . ( FromJSON b, TriggerEvent t m, PerformEvent t m, MonadSample t m
                       , HasJSContext (Performable m), MonadIO (Performable m)
                       , Reflex t, HasJSContext m, MonadJSM m )
                     => Dynamic t (Maybe JSString) -> m (Event t (Either JSError b))
httpGetNowOrOnUpdate mUrlD = do
  mUrl <- sample $ current mUrlD
  case mUrl of
    Just url -> httpGetNow url
    Nothing  -> httpGet $ fmapMaybe id $ updated mUrlD

-- | make HTTP request immediately
doHttp :: forall a b m
        . ( FromJSON b, IsXhrPayload a
          , HasJSContext m, MonadJSM m )
       => XhrRequest a -> (Either JSError b -> IO ()) -> m ()
doHttp reqConfig cb = void $ newXMLHttpRequestWithError reqConfig cb'
   where
      cb' :: Either XhrException XhrResponse -> IO ()
      cb' = handleErr >=> parseResp >=> cb
      parseResp =
        let parseJson (Just t) = parseJSONValue $ toJSString t
            parseJson Nothing  = return $ Left mempty
            go val = case fromJSON val of
                       JSON.Success v -> Right v
                       JSON.Error str -> Left $ JSError $ pack str
        in fmap ((>>= go) . join) . sequence
         . fmap (parseJson . _xhrResponse_responseText)
      handleErr (Right res) =
        let status = fromIntegral $ _xhrResponse_status res
            fromMay (Just err) = textToJSString err
            fromMay Nothing    = toJSString $ show status
            fromJSONMay x = case fromJSON x of
              JSON.Success v -> v
              JSON.Error  _ -> Nothing
        in  if status >= 200 && status < (300::Int)
            then pure $ Right res
            else do
              jserr <- maybe (pure $ Left "")
                             (parseJSONValue . toJSString)
                     $ _xhrResponse_responseText res
              return $ case jserr of
                Left _ -> Left . JSError . fromMay $ _xhrResponse_responseText res
                Right v -> Left . JSError . fromMay $
                   JSON.lookup ("message" :: JSString) v >>= fromJSONMay
      handleErr (Left XhrException_Error)   = pure $ Left "XHR Error"
      handleErr (Left XhrException_Aborted) = pure $ Left "XHR Aborted"

getReqConfig :: JSString -> XhrRequest ()
getReqConfig url = XhrRequest "GET" (textFromJSString url) $ def {
                       _xhrRequestConfig_headers  = acceptJSON
                     }

-- | Create a "POST" request from an URL and thing with a JSON representation
--   based on Reflex.Dom.Xhr (postJson)
postJsonReqConfig :: (ToJSON a) => JSString -> a -> XhrRequest JSString
postJsonReqConfig url payload =
  XhrRequest "POST" (textFromJSString url) $ def {
                        _xhrRequestConfig_headers  = headerUrlEnc
                      , _xhrRequestConfig_sendData = body
                      }
  where headerUrlEnc = "Content-type" =: "application/json"
                    <> acceptJSON
        body = encode $ toJSON payload


-- | Create a "PUT" request from an URL and thing with a JSON representation
--   based on Reflex.Dom.Xhr (postJson)
putJsonReqConfig :: (ToJSON a) => JSString -> a -> XhrRequest JSString
putJsonReqConfig url payload =
  XhrRequest "PUT" (textFromJSString url) $ def {
                        _xhrRequestConfig_headers  = headerUrlEnc
                      , _xhrRequestConfig_sendData = body
                      }
  where headerUrlEnc = "Content-type" =: "application/json"
                    <> acceptJSON
        body = encode $ toJSON payload

acceptJSON :: Map Text Text
acceptJSON = "Accept" =: "application/json,text/plain;q=0.9"
