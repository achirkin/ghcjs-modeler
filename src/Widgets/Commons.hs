{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}

module Widgets.Commons
    ( -- * Buttons
      buttonFlat, buttonFlatDyn
    , buttonRed
    , hr
      -- * Common classes to use
    , smallMarginClass
      -- * Helpers
    , whenActive
      -- * Common CSS
    , WidgetCSSClasses (..), widgetCSS
    ) where

import Reflex.Dom
import Commons
import Widgets.Generation

-- | Render a button with a click event attached.
--   Click event is labeled with a component name.
buttonFlat :: forall s t m
            . (Reflex t, DomBuilder t m)
           => Text  -- ^ name of the button
           -> Map Text Text -- ^ additional attributes
           -> m (Event t (ElementClick s))
buttonFlat name moreAttrs = do
    (e, _) <- elAttr' "a" attrs $ text name
    return $ ElementClick <$ domEvent Click e
  where
    attrs = "class" =: ("btn btn-flat btn-brand-accent waves-attach waves-effect " <> smallMarginClass) <> moreAttrs

-- | Render a button with a click event attached.
--   Hide the button if supplied Dynamic ComponentState is Inactive,
--   show button if the supplied state is Active.
--   Click event is labeled with a component name.
buttonFlatDyn :: forall s t m
                   . (Reflex t, DomBuilder t m, PostBuild t m)
                  => Dynamic t (ComponentState s) -- ^ Active or Inactive
                  -> Text          -- ^ name of the button
                  -> Map Text Text -- ^ additional attributes
                  -> m (Event t (ElementClick s))
buttonFlatDyn stateDyn name moreAttrs = do
    (e, _) <- elDynAttr' "a" (fmap stateToAttr stateDyn) $ text name
    return $ ElementClick <$ domEvent Click e
  where
    stateToAttr Active   = attrs
    stateToAttr Inactive = attrs <> ("style" =: "display: none;")
    attrs = "class" =: ("btn btn-flat btn-brand-accent waves-attach waves-effect "
                          <> smallMarginClass) <> moreAttrs

-- | Render a button with a click event attached.
--   Click event is labeled with a component name.
buttonRed :: forall s t m
           . (Reflex t, DomBuilder t m)
          => Text  -- ^ name of the button
          -> Map Text Text -- ^ additional attributes
          -> m (Event t (ElementClick s))
buttonRed name moreAttrs = do
    (e, _) <- elAttr' "a" attrs $ text name
    return $ ElementClick <$ domEvent Click e
  where
    attrs = "class" =: ("btn btn-red waves-attach waves-light waves-effect " <> smallMarginClass) <> moreAttrs

-- | Horizontal line with not so much spacing around
hr :: (Reflex t, DomBuilder t m) => m ()
hr = elAttr "hr" ("style" =: "margin: 5px 0px 5px 0px") (pure ())


-- | add this class to make a small margin between buttons
smallMarginClass :: Text
smallMarginClass = $(do
    c <- newVar
    qcss [cassius|
          .#{c}
            margin: 2px
         |]
    returnVars [c]
  )

whenActive :: (Reflex t, MonadSample t m, DomBuilder t m, MonadHold t m)
           => Dynamic t (ComponentState s) -> m () -> m ()
whenActive cstateD w = do
    cstateI <- sample $ current cstateD
    void $ widgetHold (whenActiveF cstateI) (whenActiveF <$> updated cstateD)
  where
    whenActiveF Active   = w
    whenActiveF Inactive = blank

-- | Overwrite bootstrap css a bit
data WidgetCSSClasses
  = WidgetCSSClasses
  { spaces0px     :: Text -- ^ set both padding and margin to 0 px
  , spaces2px     :: Text -- ^ set both padding and margin to 2 px
  , icon24px      :: Text -- ^ material icon that is 24 px size
  , smallP        :: Text -- ^ compact paragraphs
  , cardSpaces    :: Text -- ^ spaces between generic cards on the panel
  }


widgetCSS :: WidgetCSSClasses
widgetCSS = $(do
    spaces0pxCls     <- newVar
    spaces2pxCls     <- newVar
    icon24pxCls      <- newVar
    smallPCls        <- newVar
    cardSpacesCls    <- newVar
    qcss
      [cassius|
        .#{spaces0pxCls}
          padding: 0
          margin: 0

        .#{spaces2pxCls}
          padding: 2px
          margin: 2px

        .#{icon24pxCls}
          height: 24px
          width: 24px
          font-size: 16px
          padding: 4px

        .#{smallPCls}
          margin: 2px
          padding: 0px
          line-height: 24px

        .#{cardSpacesCls}
          margin: 5px 0 5px auto
          padding: 0px
      |]
    [| WidgetCSSClasses
          { spaces0px     = $(returnVars [spaces0pxCls])
          , spaces2px     = $(returnVars [spaces2pxCls])
          , icon24px      = $(returnVars [icon24pxCls])
          , smallP        = $(returnVars [smallPCls])
          , cardSpaces    = $(returnVars [cardSpacesCls])
          }
     |]
  )
