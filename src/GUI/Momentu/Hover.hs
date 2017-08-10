{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, DeriveFunctor, FlexibleInstances, MultiParamTypeClasses, TypeFamilies, FlexibleContexts #-}
module GUI.Momentu.Hover
    ( AnchoredWidget, anchor
    , hoverInPlaceOf, hoverBesideOptions, hoverBesideOptionsAxis
    , Orientation(..)
    ) where

import qualified Control.Lens as Lens
import           Data.List.Utils (minimumOn)
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Align (Aligned(..), value)
import           GUI.Momentu.Glue (Glue(..), Orientation)
import qualified GUI.Momentu.Glue as Glue
import           GUI.Momentu.Rect (Rect(..))
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.View as View
import           GUI.Momentu.Widget (Widget(..), R, EventResult)
import qualified GUI.Momentu.Widget as Widget

import           Lamdu.Prelude

data AnchoredWidget a = AnchoredWidget
    { _anchorPoint :: Vector2 R
    , _anchored :: Widget a
    } deriving Functor
Lens.makeLenses ''AnchoredWidget

instance Widget.HasWidget AnchoredWidget where widget = anchored

instance Functor f => View.Element (AnchoredWidget (f EventResult)) where
    setLayers = anchored . View.setLayers
    hoverLayers = anchored %~ View.hoverLayers
    empty = AnchoredWidget 0 View.empty
    assymetricPad tl br (AnchoredWidget point w) =
        AnchoredWidget
        { _anchorPoint = point + tl
        , _anchored = View.assymetricPad tl br w
        }
    scale ratio (AnchoredWidget point w) =
        AnchoredWidget
        { _anchorPoint = point * ratio
        , _anchored = View.scale ratio w
        }

instance Functor f => View.SizedElement (AnchoredWidget (f EventResult)) where
    size = anchored . View.size

instance Functor f => Glue (AnchoredWidget (f EventResult)) View where
    type Glued (AnchoredWidget (f EventResult)) View = AnchoredWidget (f EventResult)
    glue = Glue.glueH $ \w v -> w & View.setLayers <>~ View.hoverLayers v ^. View.vAnimLayers

instance Functor f => Glue View (AnchoredWidget (f EventResult)) where
    type Glued View (AnchoredWidget (f EventResult)) = AnchoredWidget (f EventResult)
    glue = Glue.glueH $ \v w -> w & View.setLayers <>~ View.hoverLayers v ^. View.vAnimLayers

instance Functor f => Glue (AnchoredWidget (f EventResult)) (Widget (f EventResult)) where
    type Glued (AnchoredWidget (f EventResult)) (Widget (f EventResult)) = AnchoredWidget (f EventResult)
    glue orientation =
        Glue.glueH f orientation
        where
            f (AnchoredWidget pos w0) w1 =
                AnchoredWidget pos (Widget.glueStates orientation w0 (View.hoverLayers w1))

instance Functor f => Glue (Widget (f EventResult)) (AnchoredWidget (f EventResult)) where
    type Glued (Widget (f EventResult)) (AnchoredWidget (f EventResult)) = AnchoredWidget (f EventResult)
    glue orientation =
        Glue.glueH f orientation
        where
            f w0 (AnchoredWidget pos w1) =
                AnchoredWidget pos (Widget.glueStates orientation (View.hoverLayers w0) w1)

anchor :: Widget a -> AnchoredWidget a
anchor = AnchoredWidget 0

hoverBesideOptions ::
    ( Glue a b, Glue b a, Glued a b ~ Glued b a
    , View.SizedElement a, View.SizedElement b, View.SizedElement (Glued a b)
    ) =>
    a -> b -> [Glued a b]
hoverBesideOptions hover src =
    do
        o <- [Glue.Vertical, Glue.Horizontal]
        hoverBesideOptionsAxis o hover src

hoverBesideOptionsAxis ::
    ( Glue a b, Glue b a, Glued a b ~ Glued b a
    , View.SizedElement a, View.SizedElement b, View.SizedElement (Glued a b)
    ) =>
    Orientation -> a -> b -> [Glued a b]
hoverBesideOptionsAxis o hover src =
    do
        x <- [0, 1]
        let aSrc = Aligned x src
        let aHover = Aligned x hover
        [glue o aSrc aHover, glue o aHover aSrc] <&> (^. value)

hoverInPlaceOf ::
    Functor f =>
    [AnchoredWidget (f EventResult)] ->
    AnchoredWidget (f EventResult) -> Widget (f EventResult)
hoverInPlaceOf [] _ = error "no hover options!"
hoverInPlaceOf hoverOptions@(defaultOption:_) place
    | null focusedOptions =
        View.assymetricPad (translation defaultOption) 0 (defaultOption ^. anchored)
        & View.size .~ place ^. View.size
    | otherwise =
        Widget
        { Widget._wSize = place ^. View.size
        , Widget._wState = Widget.StateFocused makeFocused
        }
    where
        translation hover = place ^. anchorPoint - hover ^. anchorPoint
        -- All hovers *should* be same the - either focused or unfocused..
        focusedOptions =
            do
                x <- hoverOptions
                mkFocused <- x ^.. anchored . Widget.wState . Widget._StateFocused
                return (x, mkFocused)
        makeFocused surrounding =
            surrounding
            & Widget.sRight -~ sizeDiff ^. _1
            & Widget.sBottom -~ sizeDiff ^. _2
            & Widget.translateFocused (translation hover) hMakeFocused
            & Widget.fFocalAreas %~ (Rect 0 (place ^. View.size) :)
            where
                (hover, hMakeFocused) = pickOption surrounding
                sizeDiff = hover ^. View.size - place ^. View.size
        pickOption surrounding = minimumOn (negate . remainSurrouding surrounding . (^. _1)) focusedOptions
        remainSurrouding surrounding hover =
            filter (>= 0)
            [ surrounding ^. Widget.sLeft - tl ^. _1
            , surrounding ^. Widget.sTop - tl ^. _2
            , surrounding ^. Widget.sRight - br ^. _1
            , surrounding ^. Widget.sBottom - br ^. _2
            ]
            & length
            where
                tl = negate (translation hover)
                br = hover ^. View.size - place ^. View.size - tl