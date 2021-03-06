{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
-- | Dynamics and events related to actions on scenario objects
module Program.Scenario.Object
    ( QEventTag (..)
    , objectSelectionsDyn
    , colorObjectsOnSelection
    , moveSelectedObjects
    ) where


import           Commons

--import qualified Data.Map.Strict as Map
import           Data.Maybe (isJust, maybeToList, mapMaybe, fromMaybe)
import           Data.Foldable (foldl')
import           Reflex
import           Reflex.Dom.Widget.Animation (AnimationHandler)
import qualified Reflex.Dom.Widget.Animation as Animation
import           Control.Lens
import           Control.Applicative ((<|>))
import           Numeric.DataFrame (fromHom, eye, fromScalar) -- Mat44f, (%*))
import qualified QuaTypes

import           Model.Camera (Camera)
import           Model.Scenario (Scenario)
import qualified Model.Scenario as Scenario
import           Model.Scenario.Object (ObjectId (..))
import qualified Model.Scenario.Object as Object
import           Model.Scenario.Properties

import           Program.UserAction
import           Program.Camera
import           Program.Scenario


import qualified SmallGL
--import qualified SmallGL.Types as SmallGL



-- | Selected object id events.
--   They happen when user clicks on a canvas;
--   Either some object is selected, or nothing (clicked on empty or non-selectable space).
--   The dynamic returned is guaranteed to change on every update.
objectSelectionsDyn :: Reflex t
                    => AnimationHandler t
                    -> SmallGL.RenderingApi
                    -> QuaWidget t x (Dynamic t (Maybe ObjectId))
objectSelectionsDyn aHandler renderingApi = do
    autoSelectE <- askEvent $ UserAction AskSelectObject
    selectorClickE <- performEvent $ getClicked renderingApi
                                  <$> Animation.downPointersB aHandler
                                  <@ select (Animation.pointerEvents aHandler) PClickEvent
    selIdD <- accumMaybe (\i j -> if i == j then Nothing else Just j)
                         Nothing $ leftmost [ selectorClickE, autoSelectE ]
    logDebugEvents' @JSString "Program.Scenario.Object" $ (,) "selectedObjId" . Just <$> updated selIdD
    return selIdD


-- | Color objects when they are selected or unselected.
colorObjectsOnSelection :: Reflex t
                        => Behavior t Scenario
                        -> Dynamic t (Maybe ObjectId)
                        -> QuaViewM t ()
colorObjectsOnSelection scB selObjD =
    registerEvent (SmallGLInput SmallGL.SetObjectColor) . nonEmptyOnly
       $ ( \scenario oldOId newOId ->
             do
              (i, mainObj) <- getObj scenario oldOId
              obj <- mainObj : getGroup i scenario mainObj
              return ( obj^.Object.renderingId
                     , Scenario.resolvedObjectColor scenario obj ^. colorVeci )
             <>
             do
              (i, mainObj) <- getObj scenario newOId
              ( mainObj^.Object.renderingId
               , selectedColor scenario $ mainObj^.Object.objectBehavior  )
               : do
                 obj <- getGroup i scenario mainObj
                 return ( obj^.Object.renderingId
                        , scenario^.Scenario.selectedGroupColor.colorVeci
                        )
         )
      <$> scB <*> current selObjD <@> updated selObjD
  where
    getObj scenario moid = maybeToList $ moid >>= \i -> (,) i <$> scenario ^. Scenario.objects . at i
    getGroup j scenario obj = maybeToList (obj^.Object.groupID)
                          >>= (\i -> scenario^..Scenario.viewState
                                               .Scenario.objectGroups
                                               .at i._Just
                                               .to (filter (j /=))
                                               .traverse)
                          >>= (\i -> scenario^..Scenario.objects.at i._Just)
    selectedColor sc Object.Dynamic = sc^.Scenario.selectedDynamicColor.colorVeci
    selectedColor sc Object.Static  = sc^.Scenario.selectedStaticColor.colorVeci



{- | Move objects when they are selected and dragged.

     This function must be quite complicated, because we have to update object geometry only on
     end-of-transform events to avoid object shivering and other graphics artifacts and make object
     motion more stable (pointer-move events are too often, which leads to all sorts of these problems).

     Therefore, we have to keep a snapshot of object geometry everytime we select an object.
     Thus, on every pointer-move we can update visual position of an object (in webgl) while not
     touching the real recorded object position.
     Then, on pointer-up event we update real position with a well-defined transform matrix.

     This monadic function consists of several steps:

     1. Record (as a behavior) center of the last selected group of objects (used for rotation).
     2. Use `objectTransformEvents` when selected object dynamic is not Nothing.
     3. Ask SmallGL to take snapshots of geometry on checkpoint events.
     4. Ask SmallGL to temporary update geometry on pointer-move events.
     5. Persist changes on checkpoint events by firing ObjectLocationUpdated events
         (and event consumer (Program.Scenario) should ask SmallGL to update geometry one more time)
     6. Return bool behavior whether camera should be locked by object actions
-}
moveSelectedObjects :: Reflex t
                    => AnimationHandler t
                    -> SmallGL.RenderingApi
                    -> Behavior t Camera
                    -> Behavior t Scenario
                    -> Dynamic t (Maybe ObjectId)
                    -> QuaViewM t (Behavior t Bool)
moveSelectedObjects aHandler renderingApi cameraB scenarioB selObjIdD = do
    canMove <- fmap (not . QuaTypes.isViewerOnly . QuaTypes.permissions) <$> quaSettings

    -- if the object is pointerDown'ed
    let downsE = gate (current canMove)
               $ push (fmap Just . getClicked renderingApi)
               $ Animation.curPointersB aHandler
              <@ gate -- track pointer-downs only when an object is selected and dynamic
                ((\mo -> mo ^? _Just . Object.objectBehavior == Just Object.Dynamic) <$> selectedObjB)
                (select (Animation.pointerEvents aHandler) PDownEvent)

    -- We lock camera movemement and activate object transform when a pointer is down on a selected
    -- object. If there are more than one pointer, we reset object motion every up or down event
    -- to change motion mode correcty. However, if camera is not locked before pointer up event,
    -- the event should not fire to avoid unnecessary trivial geometry updates.
    rec  camLockedD <- holdDyn False camLockedE
         ptrNB <- accum (&) (0 :: Int)
                  $ leftmost [ (+1) <$ downsE
                             , (\n -> max 0 (n-1)) <$ upsE
                             , (\n -> max 0 (n-1)) <$ clicksE
                             , (const 0 :: Int -> Int) <$ cancelsE
                             ]
         let upsE = select (Animation.pointerEvents aHandler) PUpEvent
             clicksE = select (Animation.pointerEvents aHandler) PClickEvent
             cancelsE = select (Animation.pointerEvents aHandler) PCancelEvent
             downME = downF <$> ptrNB <*> current camLockedD <*> selectedGroupObjIdsB <@> downsE
             downF :: Int -> Bool -> [ObjectId] -> Maybe ObjectId -> Maybe Bool
             downF ptrN wasLocked wasSelected isPressed
                | ptrN > 0 && wasLocked     = Just True
                | ptrN > 0 && not wasLocked = Nothing
                | Just i <- isPressed
                , i `elem` wasSelected      = Just True
                | otherwise                 = Nothing
             clickME = upF <$> ptrNB <*> current camLockedD <@ clicksE
             upME = upF <$> ptrNB <*> current camLockedD <@ upsE
             upF :: Int -> Bool -> Maybe Bool
             upF ptrN wasLocked
                | wasLocked && ptrN > 1 = Just True
                | wasLocked             = Just False
                | otherwise             = Nothing
             cancelME = cancelF <$> current camLockedD <@ cancelsE
             cancelF wasLocked
                | wasLocked = Just False
                | otherwise = Nothing
             camLockedE = fmapMaybe id $ leftmost [cancelME, upME, clickME, downME]



    -- events of object transforms
    let transformE = gate (current camLockedD)
                   $ leftmost
                     [ eye <$ updated camLockedD
                     , objectTransformEvents aHandler cameraB centerPosB
                     ]

    transformB <- hold eye transformE


    -- Every time camera UNLOCKED event happens, or LOCKED->LOCKED event happens,
    --  we need to persist current changes
    let persistGeomChangeE = fmapMaybe id
                           $ (\oids m wasLocked -> if wasLocked && not (null oids)
                                                   then Just (oids,m) else Nothing )
                          <$> selectedGroupObjIdsB
                          <*> transformB
                          <*> current camLockedD
                          <@ updated camLockedD

    registerEvent (ScenarioUpdate ObjectLocationUpdated) persistGeomChangeE
    registerEvent (SmallGLInput SmallGL.PersistGeomTransforms)
        $ (\s (is, m) -> (\o -> (o ^. Object.renderingId,m))
                      <$> mapMaybe (\i -> s ^. Scenario.objects . at i) is
          )
       <$> scenarioB
       <@> persistGeomChangeE
    registerEvent (SmallGLInput SmallGL.TransformObject)
        $ nonEmptyOnly
        $ (\ids m -> flip (,) m <$> ids)
       <$> selectedRenderingIdsB <@> transformE



    logDebugEvents' @JSString "Program.Object"
         $ (,)  "Camera-locked state:" . Just
        <$> updated camLockedD
    return $ current camLockedD
  where
    selectedObjB = (\s mi -> mi >>= \i -> s ^. Scenario.objects . at i)
                <$> scenarioB <*> current selObjIdD
    selectedGroupIdB = preview (_Just.Object.groupID._Just) <$> selectedObjB
    selectedGroupObjIdsB = (\selOid s mi -> fromMaybe [] $
                               (mi >>= \i -> s ^. Scenario.viewState.Scenario.objectGroups.at i)
                               <|> fmap (:[]) selOid
                           )
                        <$> current selObjIdD <*> scenarioB <*> selectedGroupIdB
    selectedGroupB = (\s is -> is >>= \i -> s ^.. Scenario.objects . at i . _Just)
                  <$> scenarioB <*> selectedGroupObjIdsB
    selectedRenderingIdsB = map (view Object.renderingId) <$> selectedGroupB
    -- find center position for correct rotation
    centerPosB = (\cs -> foldl' (+) 0 cs / fromScalar (max 1 . fromIntegral $ length cs))
               . map (fromHom . view Object.center)
               <$> selectedGroupB


nonEmptyOnly :: Reflex t => Event t [a] -> Event t [a]
nonEmptyOnly = ffilter (not . null)


-- | Helper function to determine ObjectId of a currently hovered object.
getClicked :: MonadIO m => SmallGL.RenderingApi -> [(Double,Double)] -> m (Maybe ObjectId)
getClicked _ []
    = pure Nothing
getClicked renderingApi ((x,y):xs)
    = (fmap f . liftIO $ SmallGL.getHoveredSelId renderingApi (round x, round y))
      -- try one more time
      >>= \mi -> if isJust mi then pure mi else getClicked renderingApi xs
  where
    f oid = if oid == 0xFFFFFFFF then Nothing else Just (ObjectId oid)
