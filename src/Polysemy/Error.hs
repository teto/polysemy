{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TemplateHaskell     #-}

module Polysemy.Error
  ( -- * Effect
    Error (..)

    -- * Actions
  , throw
  , catch
  , fromEither
  , fromEitherM
  , fromException
  , fromExceptionVia
  , fromExceptionSem
  , fromExceptionSemVia
  , note
  , try
  , tryJust
  , catchJust

    -- * Interpretations
  , runError
  , mapError
  , errorToIOFinal
  , lowerError
  ) where

import qualified Control.Exception as X
import           Control.Monad
import qualified Control.Monad.Trans.Except as E
import           Data.Bifunctor (first)
import           Data.Typeable
import           Polysemy
import           Polysemy.Final
import           Polysemy.Internal
import           Polysemy.Internal.Union


data Error e m a where
  Throw :: e -> Error e m a
  Catch :: ∀ e m a. m a -> (e -> m a) -> Error e m a

makeSem ''Error

------------------------------------------------------------------------------
-- | Upgrade an 'Either' into an 'Error' effect.
--
-- @since 0.5.1.0
fromEither
    :: Member (Error e) r
    => Either e a
    -> Sem r a
fromEither (Left e) = throw e
fromEither (Right a) = pure a
{-# INLINABLE fromEither #-}

------------------------------------------------------------------------------
-- | A combinator doing 'embed' and 'fromEither' at the same time. Useful for
-- interoperating with 'IO'.
--
-- @since 0.5.1.0
fromEitherM
    :: forall e m r a
     . ( Member (Error e) r
       , Member (Embed m) r
       )
    => m (Either e a)
    -> Sem r a
fromEitherM = fromEither <=< embed
{-# INLINABLE fromEitherM #-}


------------------------------------------------------------------------------
-- | Lift an exception generated from an 'IO' action into an 'Error'.
fromException
    :: forall e r a
     . ( X.Exception e
       , Member (Error e) r
       , Member (Embed IO) r
       )
    => IO a
    -> Sem r a
fromException = fromExceptionVia @e id
{-# INLINABLE fromException #-}


------------------------------------------------------------------------------
-- | Like 'fromException', but with the ability to transform the exception
-- before turning it into an 'Error'.
fromExceptionVia
    :: ( X.Exception exc
       , Member (Error err) r
       , Member (Embed IO) r
       )
    => (exc -> err)
    -> IO a
    -> Sem r a
fromExceptionVia f m = do
  r <- embed $ X.try m
  case r of
    Left e -> throw $ f e
    Right a -> pure a
{-# INLINABLE fromExceptionVia #-}

------------------------------------------------------------------------------
-- | Run a @Sem r@ action, converting any 'IO' exception generated by it into an 'Error'.
fromExceptionSem
    :: forall e r a
     . ( X.Exception e
       , Member (Error e) r
       , Member (Final IO) r
       )
    => Sem r a
    -> Sem r a
fromExceptionSem = fromExceptionSemVia @e id
{-# INLINABLE fromExceptionSem #-}

------------------------------------------------------------------------------
-- | Like 'fromExceptionSem', but with the ability to transform the exception
-- before turning it into an 'Error'.
fromExceptionSemVia
    :: ( X.Exception exc
       , Member (Error err) r
       , Member (Final IO) r
       )
    => (exc -> err)
    -> Sem r a
    -> Sem r a
fromExceptionSemVia f m = do
  r <- withStrategicToFinal $ do
    m' <- runS m
    s  <- getInitialStateS
    pure $ (fmap . fmap) Right m' `X.catch` \e -> (pure (Left e <$ s))
  case r of
    Left e -> throw $ f e
    Right a -> pure a
{-# INLINABLE fromExceptionSemVia #-}

------------------------------------------------------------------------------
-- | Attempt to extract a @'Just' a@ from a @'Maybe' a@, throwing the
-- provided exception upon 'Nothing'.
note :: Member (Error e) r => e -> Maybe a -> Sem r a
note e Nothing  = throw e
note _ (Just a) = pure a
{-# INLINABLE note #-}

------------------------------------------------------------------------------
-- | Similar to @'catch'@, but returns an @'Either'@ result which is (@'Right' a@)
-- if no exception of type @e@ was @'throw'@n, or (@'Left' ex@) if an exception of type
-- @e@ was @'throw'@n and its value is @ex@.
try :: Member (Error e) r => Sem r a -> Sem r (Either e a)
try m = catch (Right <$> m) (return . Left)
{-# INLINABLE try #-}

------------------------------------------------------------------------------
-- | A variant of @'try'@ that takes an exception predicate to select which exceptions
-- are caught (c.f. @'catchJust'@). If the exception does not match the predicate,
-- it is re-@'throw'@n.
tryJust :: Member (Error e) r => (e -> Maybe b) -> Sem r a -> Sem r (Either b a)
tryJust f m = do
    r <- try m
    case r of
      Right v -> return (Right v)
      Left e -> case f e of
                  Nothing -> throw e
                  Just b -> return $ Left b
{-# INLINABLE tryJust #-}

------------------------------------------------------------------------------
-- | The function @'catchJust'@ is like @'catch'@, but it takes an extra argument
-- which is an exception predicate, a function which selects which type of exceptions
-- we're interested in.
catchJust :: Member (Error e) r
          => (e -> Maybe b) -- ^ Predicate to select exceptions
          -> Sem r a  -- ^ Computation to run
          -> (b -> Sem r a) -- ^ Handler
          -> Sem r a
catchJust ef m bf = catch m handler
  where
      handler e = case ef e of
                    Nothing -> throw e
                    Just b -> bf b
{-# INLINABLE catchJust #-}

------------------------------------------------------------------------------
-- | Run an 'Error' effect in the style of
-- 'Control.Monad.Trans.Except.ExceptT'.
runError
    :: Sem (Error e ': r) a
    -> Sem r (Either e a)
runError (Sem m) = Sem $ \k -> E.runExceptT $ m $ \u ->
  case decomp u of
    Left x ->
      liftHandlerWithNat (E.ExceptT . runError) k x
    Right (Weaving (Throw e) _ _ _) -> E.throwE e
    Right (Weaving (Catch main handle) mkT lwr ex) ->
      E.ExceptT $ usingSem k $ do
        ea <- runError $ lwr $ mkT id main
        case ea of
          Right a -> pure . Right $ ex a
          Left e -> do
            ma' <- runError $ lwr $ mkT id $ handle e
            case ma' of
              Left e' -> pure $ Left e'
              Right a -> pure . Right $ ex a
{-# INLINE runError #-}

------------------------------------------------------------------------------
-- | Transform one 'Error' into another. This function can be used to aggregate
-- multiple errors into a single type.
--
-- @since 1.0.0.0
mapError
  :: forall e1 e2 r a
   . Member (Error e2) r
  => (e1 -> e2)
  -> Sem (Error e1 ': r) a
  -> Sem r a
mapError f = interpretNew $ \case
  Throw e -> throw $ f e
  Catch action handler ->
    runError (runH' action) >>= \case
      Right x -> pure x
      Left e  -> runH (handler e)
{-# INLINE mapError #-}


newtype WrappedExc e = WrappedExc { unwrapExc :: e }
  deriving (Typeable)

instance Typeable e => Show (WrappedExc e) where
  show = mappend "WrappedExc: " . show . typeRep

instance (Typeable e) => X.Exception (WrappedExc e)


------------------------------------------------------------------------------
-- | Run an 'Error' effect as an 'IO' 'X.Exception' through final 'IO'. This
-- interpretation is significantly faster than 'runError'.
--
-- /Beware/: Effects that aren't interpreted in terms of 'IO'
-- will have local state semantics in regards to 'Error' effects
-- interpreted this way. See 'Final'.
--
-- @since 1.2.0.0
errorToIOFinal
    :: ( Typeable e
       , Member (Final IO) r
       )
    => Sem (Error e ': r) a
    -> Sem r (Either e a)
errorToIOFinal sem = withStrategicToFinal @IO $ do
  m' <- runS (runErrorAsExcFinal sem)
  s  <- getInitialStateS
  pure $
    either
      ((<$ s) . Left . unwrapExc)
      (fmap Right)
    <$> X.try m'
{-# INLINE errorToIOFinal #-}

runErrorAsExcFinal
    :: forall e r a
    .  ( Typeable e
       , Member (Final IO) r
       )
    => Sem (Error e ': r) a
    -> Sem r a
runErrorAsExcFinal = interpretFinal $ \case
  Throw e   -> pure $ X.throwIO $ WrappedExc e
  Catch m h -> do
    m' <- runS m
    h' <- bindS h
    s  <- getInitialStateS
    pure $ X.catch m' $ \(se :: WrappedExc e) ->
      h' (unwrapExc se <$ s)
{-# INLINE runErrorAsExcFinal #-}

------------------------------------------------------------------------------
-- | Run an 'Error' effect as an 'IO' 'X.Exception'. This interpretation is
-- significantly faster than 'runError', at the cost of being less flexible.
--
-- @since 1.0.0.0
lowerError
    :: ( Typeable e
       , Member (Embed IO) r
       )
    => (∀ x. Sem r x -> IO x)
       -- ^ Strategy for lowering a 'Sem' action down to 'IO'. This is
       -- likely some combination of 'runM' and other interpreters composed via
       -- '.@'.
    -> Sem (Error e ': r) a
    -> Sem r (Either e a)
lowerError lower
    = embed
    . fmap (first unwrapExc)
    . X.try
    . (lower .@ runErrorAsExc)
{-# INLINE lowerError #-}
{-# DEPRECATED lowerError "Use 'errorToIOFinal' instead" #-}


-- TODO(sandy): Can we use the new withLowerToIO machinery for this?
runErrorAsExc
    :: forall e r a. ( Typeable e
       , Member (Embed IO) r
       )
    => (∀ x. Sem r x -> IO x)
    -> Sem (Error e ': r) a
    -> Sem r a
runErrorAsExc lower = interpretH $ \case
  Throw e -> embed $ X.throwIO $ WrappedExc e
  Catch main handle -> do
    is <- getInitialStateT
    m  <- runT main
    h  <- bindT handle
    let runIt = lower . runErrorAsExc lower
    embed $ X.catch (runIt m) $ \(se :: WrappedExc e) ->
      runIt $ h $ unwrapExc se <$ is
{-# INLINE runErrorAsExc #-}
