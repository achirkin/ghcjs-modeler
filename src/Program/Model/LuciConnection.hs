-----------------------------------------------------------------------------
-- |
-- Module      :  Program.Model.LuciConnection
-- Copyright   :  (c) Artem Chirkin
-- License     :  MIT
--
-- Maintainer  :  Artem Chirkin <chirkin@arch.ethz.ch>
-- Stability   :  experimental
--
--
-----------------------------------------------------------------------------
{-# LANGUAGE DataKinds, FlexibleInstances, MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
module Program.Model.LuciConnection
  ( luciBehavior
  ) where

--import Control.Concurrent

-- Various thins I use
--import Control.Arrow (second)
--import Data.Geometry
--import JsHs
import JsHs.JSString (pack, unpack') -- JSString, append
--import Control.Monad (void, when)
import JsHs.Useful
import JsHs
import JsHs.Types.Prim (jsNull)
--import Text.Read (readMaybe)
--import Data.Coerce
import qualified JsHs.Array as JS
import qualified JsHs.TypedArray as JSTA
--import JsHs.WebGL.Types (GLfloat)

import Data.Geometry.Structure.Feature (FeatureCollection)
import qualified Data.Geometry.Structure.PointSet as PS

import Unsafe.Coerce (unsafeCoerce)

import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Time
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Reactive.Banana.Frameworks
import Reactive.Banana.Combinators

import Program.Settings
import Program.Controllers.LuciClient
import Program.Model.City
import Program.Types
import Program.VisualService
import qualified Program.Controllers.GUI as GUI

import JsHs.Debug

luciBehavior :: Settings
             -> (Either FeatureCollection FeatureCollection -> IO ())
                      -> Behavior City
                      -> Event GroundUpdated
                      -> Event (Either b b1)
                      -> Event b2
                      -> Event (GeomId, b3)
                      -> MomentIO (Event VisualServiceResult)
luciBehavior lsettings geoJSONImportFire cityB groundUpdatedE
             geoJSONImportE clearGeometryE motionRecordsE = mdo

      -- Luci Client testing
      (luciClientB,noCallIdMsgE,unknownMsgE) <- luciHandler (fromMaybe "" $ luciRoute lsettings)

--      -- actions to do when luci state changes
--      let doLuciAction LuciClientOpening = logText' "Opening connection."
--          doLuciAction LuciClientClosed = logText' "LuciClient WebSocket connection closed."
--          doLuciAction (LuciClientError err) = logText' $ "LuciClient error: " <> err
--          doLuciAction _luciClient = logText' "Luci is ready"
--            -- TODO: run runQuaServiceList
----            sendMessage luciClient runQuaServiceList
--      reactimate $ doLuciAction <$> luciClientE

      -- general response to luci messages
      -- get scenario
      (onScenarioGetE, onScenarioGetFire) <- newEvent


      -- asking luci for a scenario list on button click
      (getScListE, getScListFire) <- newEvent
      liftIO $ registerGetScenarioList getScListFire
      let gotScenarioListF (SRResult _ scenarioList _) = displayScenarios scenarioList
          gotScenarioListF (SRError _ err) = logText' err
          gotScenarioListF _ = return ()
      runScenarioList luciClientB (() <$ getScListE) >>= reactimate . fmap gotScenarioListF
--      callLuci (("scenario.GetList", [], []) <$ getScListE) >>= reactimate . fmap gotScenarioListF
--      execute (runScenarioList runLuciService <$ getScListE) >>= switchE >>= reactimate . fmap gotScenarioListF

      -- asking luci to save a scenario on button click
      (askSaveScenarioE, onAskSaveScenarioFire) <- newEvent
      liftIO $ GUI.registerSaveScenario onAskSaveScenarioFire
      scenarioSavedE <- runScenarioCreate luciClientB $ (\ci s -> (s, storeCityAsIs ci)) <$> cityB <@> askSaveScenarioE
--      scenarioSavedE <- execute ((\ci s -> runScenarioCreate runLuciService s (storeCityAsIs ci)) <$> cityB <@> askSaveScenarioE) >>= switchE
      scenarioSyncE_create <- mapEventIO id
           $ (\s -> do
              GUI.toggleSaveScenarioButton False s
              return $ SSPendingCreate s
            )
          <$> askSaveScenarioE
      let createdScenarioF (SRResult _ (LuciResultScenarioCreated scId t) _) = onScenarioGetFire (scId, t)
          createdScenarioF (SRError _ err) = logText' err
          createdScenarioF _ = return ()
      reactimate $ createdScenarioF <$> scenarioSavedE

      -- register user clicking on "get scenario" button
      (askForScenarioE, onAskForScenarioFire) <- newEvent
      liftIO $ registerAskLuciForScenario (curry onAskForScenarioFire)
      -- Asking luci for a scenario on button click
      gotScenarioE <- runScenarioGet luciClientB (fst <$> askForScenarioE)
--      gotScenarioE <- execute (runScenarioGet runLuciService . fst <$> askForScenarioE) >>= switchE
      let gotScenarioF (SRResult _ (LuciResultScenario scId fc t) _) = geoJSONImportFire (Right fc) >> onScenarioGetFire (scId, t)
          gotScenarioF (SRError _ err) = logText' err
          gotScenarioF _ = return ()
      reactimate $ gotScenarioF <$> gotScenarioE


      let getSync (SSSynced sId' name _) (sId, t) | sId == sId' && sId /= 0 = SSSynced sId name t
                                                  | otherwise = SSNotBound
          getSync SSEmpty (0, _) = SSEmpty
          getSync SSEmpty (sId, t) = SSSynced sId "Unknown scenario" t
          getSync SSNotBound (0, _) = SSNotBound
          getSync SSNotBound (sId, t) = SSSynced sId "Unknown scenario NB" t
          getSync (SSPendingCreate _) (0, _) = SSNotBound
          getSync (SSPendingCreate s) (sId, t) = SSSynced sId s t
          getSync (SSPendingGet sId' s) (sId, t) | sId == sId' && sId /= 0 = SSSynced sId s t
                                                 | otherwise = SSNotBound
      let scenarioSyncE_obtained = getSync <$> scenarioSyncB <@> onScenarioGetE
          scenarioSyncE_clearGeom = SSEmpty <$ clearGeometryE
          scenarioSyncE_extraUpdate = SSNotBound <$ fst (split geoJSONImportE)
          scenarioSyncE_get = uncurry SSPendingGet <$> askForScenarioE
          scenarioSyncE = unionsStepper [ scenarioSyncE_create
                                        , scenarioSyncE_get
                                        , scenarioSyncE_clearGeom
                                        , scenarioSyncE_extraUpdate
                                        , scenarioSyncE_obtained
                                        ]
      scenarioSyncB <- stepper SSEmpty scenarioSyncE


      -- Trying to keep scenario name
      let toggleSaveScenarioA SSEmpty = GUI.toggleSaveScenarioButton False ""
          toggleSaveScenarioA SSNotBound = GUI.toggleSaveScenarioButton True ""
          toggleSaveScenarioA (SSPendingCreate s) = GUI.toggleSaveScenarioButton False s
          toggleSaveScenarioA (SSPendingGet _ s) = GUI.toggleSaveScenarioButton False s
          toggleSaveScenarioA (SSSynced _ s t) = GUI.toggleSaveScenarioButton False
                                                 ("[" <> ScenarioName (pack $ formatTime defaultTimeLocale "%y.%m.%d-%H:%M:%S" t) <> "] " <> s)

--          updateScenarioA (SSSynced sid _ _) ci gId = runScenarioUpdate runLuciService sid (storeObjectsAsIs [gId] ci)
--          updateScenarioA _ _ _ = return never
          updateScenarioF (SSSynced sid _ _) ci gId = Just (sid, storeObjectsAsIs [gId] ci)
          updateScenarioF _ _ _ = Nothing
--
          serviceRunsE = filterJust $ serviceRunsF <$> scenarioSyncB <@> groundUpdatedE
          serviceRunsF (SSSynced sid _ _) (GroundUpdated points) = Just $ VisualServiceRunPoints sid (fromJSArrayToTypedArray $ PS.flatten points)
          serviceRunsF _ _ = Nothing

          serviceButtonF GroundUpdated{} = GUI.toggleServiceClear True
          serviceButtonF GroundCleared{} = GUI.toggleServiceClear False
--
--
--          askSubscribeForScenario SSSynced{} SSSynced{} = return never
--          askSubscribeForScenario _ (SSSynced sid _ _) = runScenarioSubscribe runLuciService sid
--          askSubscribeForScenario _ _ = return never
          -- TODO: Something is wrong with this logic, need to rethink
          askSubscribeForScenario SSSynced{} SSSynced{} = Nothing
          askSubscribeForScenario _ (SSSynced sid _ _) = Just sid
          askSubscribeForScenario _ _ = Nothing

      -- show reflect scenario sync state
      reactimate $ toggleSaveScenarioA <$> scenarioSyncE


--      -- sync geometry with Luci
      lateObjectRecordsE <- execute $ return . fst <$> motionRecordsE
      sendScenarioUpdateE <- runScenarioUpdate luciClientB . filterJust $ updateScenarioF <$> scenarioSyncB <*> cityB <@> lateObjectRecordsE
      receiveScenarioUpdateE <- runScenarioSubscribe luciClientB . filterJust $ askSubscribeForScenario <$> scenarioSyncB <@> scenarioSyncE_obtained
      let (noCallIdMsgE', subscribeToUpdatesE)
                               = split $ (\m -> if 0 == responseCallId m
                                                then Right m
                                                else Left m
                                         ) <$> noCallIdMsgE
      reactimate $ gotScenarioF . fmap (JS.asLikeJS . srVal) <$> subscribeToUpdatesE
--      scenarioOutUpdatesE <- execute (updateScenarioA <$> scenarioSyncB <*> cityB <@> lateObjectRecordsE) >>= switchE
--      scenarioInUpdatesE <- execute (askSubscribeForScenario <$>  scenarioSyncB <@> scenarioSyncE_obtained) >>= switchE
--      reactimate $ gotScenarioF <$> receiveScenarioUpdateE
      let (errsOfScOutE, _, _) = catResponses sendScenarioUpdateE
          (errsOfScInE, _, _) = catResponses receiveScenarioUpdateE
      reactimate $ logText' <$> errsOfScInE
      reactimate $ logText' <$> errsOfScOutE

      -- run luci service!
      -- vsManagerBehavior ("DistanceToWalls" <$ serviceRunsE)
      (selectServiceE, selectServiceFire) <- newEvent
      (updateSListE, updateSListFire) <- newEvent
      (changeSParamE, changeSParamFire) <- newEvent
      (vsManagerB, vsResultsE) <-vsManagerBehavior selectServiceE changeSParamE updateSListE
      -- TODO: delete following block!
      (triggerQuaServiceListE,triggerQuaServiceListF) <- newEvent
      serviceListUpdateE <- runQuaServiceList luciClientB triggerQuaServiceListE
      let serviceListUpdateA (SRResult _ r@(ServiceList jsarray) _) = do
            print $ JS.toList jsarray
            updateSListFire r
            case ServiceName <$> JS.toList jsarray of
              [] -> return ()
              (x:_) -> selectServiceFire x
          serviceListUpdateA (SRError _ e) = logText' e
          serviceListUpdateA _ = return ()
      reactimate $ serviceListUpdateA <$> serviceListUpdateE
      reactimate $ triggerQuaServiceListF <$> (() <$ gotScenarioE)


      runVService vsManagerB luciClientB serviceRunsE


--      reactimate $ (\t -> logText' t >> GUI.toggleServiceClear False) <$> vsErrsE
--      reactimate $ logText' "Service started" <$ vsProgresE
--      reactimate $ logText' "Service finished" <$ vsResultsE
      reactimate $ serviceButtonF <$> groundUpdatedE

      reactimate $ (\(msg, _) -> print $ "Ignoring message: " ++ (unpack' . jsonStringify $ JS.asJSVal msg)) <$> unknownMsgE
      reactimate $ (\msg -> print $ "Ignoring message: " ++ show (fmap (unpack' . jsonStringify . srVal) msg)) <$> noCallIdMsgE'


      return vsResultsE








----------------------------------------------------------------------------------------------------
-- * Pre-defined messages
----------------------------------------------------------------------------------------------------

--runHelper :: JS.LikeJS s a => ServiceName -> [(JSString, JSVal)] -> ServiceInvocation -> MomentIO (Event (Either JSString a))
--runHelper sname pams run = filterJust . fmap f <$> run sname pams []
--  where
--    f (SRResult _ (ServiceResult res) _) = Just . Right $ JS.asLikeJS res
--    f SRProgress{} = Nothing
--    f (SRError _ s) = Just $ Left s

-- | A message to get list of available services from luci
runServiceList :: Behavior LuciClient -> Event () -> MomentIO (Event (ServiceResponse LuciResultServiceList))
runServiceList lcB e = runService lcB $ ("ServiceList",[],[]) <$ e


---- | run a testing service test.Fibonacci
--runTestFibonacci :: Int -> LuciMessage
--runTestFibonacci n = toLuciMessage (MsgRun "test.Fibonacci" [("amount", JS.asJSVal n)]) []

--newtype LuciResultTestFibonacci = TestFibonacci [Int]
--  deriving (Show, Eq)
--instance LikeJS "Object" LuciResultTestFibonacci where
--  asLikeJS b = case getProp "fibonacci_sequence" b of
--                 Just x  -> TestFibonacci $ JS.asLikeJS x
--                 Nothing -> TestFibonacci []
--  asJSVal (TestFibonacci xs) = setProp "fibonacci_sequence" xs newObj



-- | Luci scenario
data LuciScenario = LuciResultScenario ScenarioId FeatureCollection UTCTime
instance JS.LikeJS "Object" LuciScenario where
  asLikeJS jsv = case (,) <$> getProp "ScID" jsv <*> getProp "FeatureCollection" jsv of
                  Just (scId, fc) -> LuciResultScenario scId fc t
                  Nothing -> anotherTry
     where
       t = posixSecondsToUTCTime . realToFrac . secondsToDiffTime . fromMaybe 0 $ getProp "lastmodified" jsv
       anotherTry = LuciResultScenario (fromMaybe 0 $ getProp "ScID" jsv)
              (fromMaybe (JS.fromJSArray JS.emptyArray) (getProp "geometry_output" jsv >>= getProp "geometry")) t
  asJSVal (LuciResultScenario scId fc _) =
            setProp "ScID"  (JS.asJSVal scId)
          $ setProp "FeatureCollection" fc newObj

-- | Luci scenario
data LuciScenarioCreated = LuciResultScenarioCreated ScenarioId UTCTime
instance JS.LikeJS "Object" LuciScenarioCreated where
  asLikeJS jsv = LuciResultScenarioCreated (fromMaybe 0 $ getProp "ScID" jsv)
                                     (posixSecondsToUTCTime . realToFrac . secondsToDiffTime . fromMaybe 0 $ getProp "lastmodified" jsv)
  asJSVal (LuciResultScenarioCreated scId lm) =
            setProp "ScID"  (JS.asJSVal scId)
          $ setProp "lastmodified" (round $ utcTimeToPOSIXSeconds lm :: Int) newObj

-- | Pass the name of the scenario and a feature collection with geometry
runScenarioCreate :: Behavior LuciClient
                  -> Event
                     ( ScenarioName -- ^ name of the scenario
                     , FeatureCollection -- ^ content of the scenario
                     )
                  -> MomentIO (Event (ServiceResponse LuciScenarioCreated))
runScenarioCreate lcB e = runService lcB $ (\v -> ("scenario.geojson.Create", f v, [])) <$> e
  where
    f (name, collection) =
      [ ("name", JS.asJSVal name)
      , ("geometry_input"
        ,   setProp "format"  ("GeoJSON" :: JSString)
          $ setProp "geometry" collection newObj
        )
      ]
-- returns: "{"created":1470932237,"lastmodified":1470932237,"name":"dgdsfg","ScID":4}"


runScenarioUpdate :: Behavior LuciClient
                  -> Event
                     ( ScenarioId -- ^ id of the scenario
                     , FeatureCollection -- ^ content of the scenario update
                     )
                  -> MomentIO (Event (ServiceResponse JSVal))
runScenarioUpdate lcB e = runService lcB $ (\v -> ("scenario.geojson.Update", f v, [])) <$> e
  where
    f (scId, collection) =
      [ ("ScID", JS.asJSVal scId)
      , ("geometry_input"
        ,   setProp "format"  ("GeoJSON" :: JSString)
          $ setProp "geometry" collection newObj
        )
      ]


runScenarioGet :: Behavior LuciClient
               -> Event ScenarioId -- ^ id of the scenario
               -> MomentIO (Event (ServiceResponse LuciScenario))
runScenarioGet lcB e = runService lcB $ (\v -> ("scenario.geojson.Get", f v, [])) <$> e
  where
    f scId =
      [ ("ScID", JS.asJSVal scId)
      ]

-- returns: "{"lastmodified":1470932237,"ScID":4}"

runScenarioSubscribe :: Behavior LuciClient
                     -> Event ScenarioId -- ^ id of the scenario
                     -> MomentIO (Event (ServiceResponse LuciScenario))
runScenarioSubscribe lcB e = runService lcB $ (\v -> ("scenario.SubscribeTo", f v, [])) <$> e
  where
    f scId =
      [ ("ScIDs", JS.asJSVal [scId])
      , ("format", JS.asJSVal ("geojson" :: JSString))
      ]


runScenarioList :: Behavior LuciClient -> Event () -> MomentIO (Event (ServiceResponse ServiceResult))
runScenarioList lcB e = runService lcB $ ("scenario.GetList",[],[]) <$ e


newtype LuciResultScenarioList = ScenarioList [ScenarioDescription]
  deriving (Show)
instance JS.LikeJS "Object" LuciResultScenarioList where
  asLikeJS b = case getProp "scenarios" b of
                 Just x  -> ScenarioList x
                 Nothing -> ScenarioList []
  asJSVal (ScenarioList v) = setProp "scenarios" v newObj


data ScenarioDescription = ScenarioDescription
  { scCreated  :: UTCTime
  , scModified :: UTCTime
  , scName     :: ScenarioName
  , sscId      :: ScenarioId
  }
  deriving (Eq,Ord,Show)
instance JS.LikeJS "Object" ScenarioDescription where
  asLikeJS jsv = ScenarioDescription
    { scCreated  = f $ getProp "created" jsv
    , scModified = f $ getProp "lastmodified" jsv
    , scName     = fromMaybe "" $ getProp "name" jsv
    , sscId      = fromMaybe (-1) $ getProp "ScID" jsv
    }
      where
        f = posixSecondsToUTCTime . realToFrac . secondsToDiffTime . fromMaybe 0
  asJSVal scd =
          setProp "ScID" (sscId scd) . setProp "name" (scName scd)
        . setProp "lastmodified" (f $ scModified scd :: Int) $ setProp "created" (f $ scCreated scd :: Int) newObj
      where
        f = round . utcTimeToPOSIXSeconds









----------------------------------------------------------------------------------------------------
-- * Helpers
----------------------------------------------------------------------------------------------------








unionsStepper :: [Event a] -> Event a
unionsStepper [] = never
unionsStepper xs = foldr1 (unionWith (const id)) xs


fromJSArrayToTypedArray :: (JSTA.TypedArrayOperations a) => JS.Array a -> JSTA.TypedArray a
fromJSArrayToTypedArray = JSTA.fromArray . unsafeFromJSArrayCoerce

unsafeFromJSArrayCoerce :: JS.Array a -> JSTA.TypedArray a
unsafeFromJSArrayCoerce = unsafeCoerce
