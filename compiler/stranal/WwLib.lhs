%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1998
%
\section[WwLib]{A library for the ``worker\/wrapper'' back-end to the strictness analyser}

\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module WwLib ( mkWwBodies, mkWWstr, mkWorkerArgs, deepSplitProductType_maybe ) where

#include "HsVersions.h"

import CoreSyn
import CoreUtils	( exprType, mkCast )
import Id		( Id, idType, mkSysLocal, idDemandInfo, setIdDemandInfo,
			  isOneShotLambda, setOneShotLambda, setIdUnfolding,
                          setIdInfo
			)
import IdInfo		( vanillaIdInfo )
import DataCon
import Demand        
import MkCore		( mkRuntimeErrorApp, aBSENT_ERROR_ID )
import MkId		( realWorldPrimId, voidArgId )
import TysPrim		( realWorldStatePrimTy )
import TysWiredIn	( tupleCon )
import Type
import Coercion hiding  ( substTy, substTyVarBndr )
import BasicTypes	( TupleSort(..) )
import Literal		( absentLiteralOf )
import TyCon
import UniqSupply
import Unique
import Maybes
import Util
import Outputable
import DynFlags
import FastString
\end{code}


%************************************************************************
%*									*
\subsection[mkWrapperAndWorker]{@mkWrapperAndWorker@}
%*									*
%************************************************************************

Here's an example.  The original function is:

\begin{verbatim}
g :: forall a . Int -> [a] -> a

g = \/\ a -> \ x ys ->
	case x of
	  0 -> head ys
	  _ -> head (tail ys)
\end{verbatim}

From this, we want to produce:
\begin{verbatim}
-- wrapper (an unfolding)
g :: forall a . Int -> [a] -> a

g = \/\ a -> \ x ys ->
	case x of
	  I# x# -> $wg a x# ys
	    -- call the worker; don't forget the type args!

-- worker
$wg :: forall a . Int# -> [a] -> a

$wg = \/\ a -> \ x# ys ->
	let
	    x = I# x#
	in
	    case x of		    -- note: body of g moved intact
	      0 -> head ys
	      _ -> head (tail ys)
\end{verbatim}

Something we have to be careful about:  Here's an example:

\begin{verbatim}
-- "f" strictness: U(P)U(P)
f (I# a) (I# b) = a +# b

g = f	-- "g" strictness same as "f"
\end{verbatim}

\tr{f} will get a worker all nice and friendly-like; that's good.
{\em But we don't want a worker for \tr{g}}, even though it has the
same strictness as \tr{f}.  Doing so could break laziness, at best.

Consequently, we insist that the number of strictness-info items is
exactly the same as the number of lambda-bound arguments.  (This is
probably slightly paranoid, but OK in practice.)  If it isn't the
same, we ``revise'' the strictness info, so that we won't propagate
the unusable strictness-info into the interfaces.


%************************************************************************
%*									*
\subsection{The worker wrapper core}
%*									*
%************************************************************************

@mkWwBodies@ is called when doing the worker\/wrapper split inside a module.

\begin{code}
mkWwBodies :: DynFlags
       -> Type				-- Type of original function
	   -> [Demand]				-- Strictness of original function
	   -> DmdResult				-- Info about function result
	   -> [Bool]				-- One-shot-ness of the function
	   -> UniqSM ([Demand],			-- Demands for worker (value) args
		      Id -> CoreExpr,		-- Wrapper body, lacking only the worker Id
		      CoreExpr -> CoreExpr)	-- Worker body, lacking the original function rhs

-- wrap_fn_args E	= \x y -> E
-- work_fn_args E	= E x y

-- wrap_fn_str E 	= case x of { (a,b) -> 
--			  case a of { (a1,a2) ->
--			  E a1 a2 b y }}
-- work_fn_str E	= \a2 a2 b y ->
--			  let a = (a1,a2) in
--			  let x = (a,b) in
--			  E

mkWwBodies dflags fun_ty demands res_info one_shots
  = do	{ let arg_info = demands `zip` (one_shots ++ repeat False)
              all_one_shots = all snd arg_info
	; (wrap_args, wrap_fn_args, work_fn_args, res_ty) <- mkWWargs emptyTvSubst fun_ty arg_info
	; (work_args, wrap_fn_str,  work_fn_str) <- mkWWstr dflags wrap_args

        -- Do CPR w/w.  See Note [Always do CPR w/w]
	; (wrap_fn_cpr, work_fn_cpr,  cpr_res_ty) <- mkWWcpr res_ty res_info

	; let (work_lam_args, work_call_args) = mkWorkerArgs dflags work_args all_one_shots cpr_res_ty
	; return ([idDemandInfo v | v <- work_call_args, isId v],
                  wrap_fn_args . wrap_fn_cpr . wrap_fn_str . applyToVars work_call_args . Var,
                  mkLams work_lam_args. work_fn_str . work_fn_cpr . work_fn_args) }
        -- We use an INLINE unconditionally, even if the wrapper turns out to be
        -- something trivial like
        --      fw = ...
        --      f = __inline__ (coerce T fw)
        -- The point is to propagate the coerce to f's call sites, so even though
        -- f's RHS is now trivial (size 1) we still want the __inline__ to prevent
        -- fw from being inlined into f's RHS
\end{code}

Note [Always do CPR w/w]
~~~~~~~~~~~~~~~~~~~~~~~~
At one time we refrained from doing CPR w/w for thunks, on the grounds that
we might duplicate work.  But that is already handled by the demand analyser,
which doesn't give the CPR proprety if w/w might waste work: see
Note [CPR for thunks] in DmdAnal.    

And if something *has* been given the CPR property and we don't w/w, it's
a disaster, because then the enclosing function might say it has the CPR
property, but now doesn't and there a cascade of disaster.  A good example
is Trac #5920.


%************************************************************************
%*									*
\subsection{Making wrapper args}
%*									*
%************************************************************************

During worker-wrapper stuff we may end up with an unlifted thing
which we want to let-bind without losing laziness.  So we
add a void argument.  E.g.

	f = /\a -> \x y z -> E::Int#	-- E does not mention x,y,z
==>
	fw = /\ a -> \void -> E
	f  = /\ a -> \x y z -> fw realworld

We use the state-token type which generates no code.

\begin{code}
mkWorkerArgs :: DynFlags -> [Var]
             -> Bool    -- Whether all arguments are one-shot
	     -> Type	-- Type of body
	     -> ([Var],	-- Lambda bound args
		 [Var])	-- Args at call site
mkWorkerArgs dflags args all_one_shot res_ty
    | any isId args || not needsAValueLambda
    = (args, args)
    | otherwise	
    = (args ++ [newArg], args ++ [realWorldPrimId])
    where
      needsAValueLambda =
        isUnLiftedType res_ty
        || not (gopt Opt_FunToThunk dflags)
           -- see Note [Protecting the last value argument]

      -- see Note [All One-Shot Arguments of a Worker]
      newArg = if all_one_shot 
               then setOneShotLambda voidArgId
               else voidArgId     
\end{code}

Note [Protecting the last value argument]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

If the user writes (\_ -> E), they might be intentionally disallowing
the sharing of E. Since absence analysis and worker-wrapper are keen
to remove such unused arguments, we add in a void argument to prevent
the function from becoming a thunk.

The user can avoid that argument with the -ffun-to-thunk
flag. However, removing all the value argus may introduce space leaks.

Note [All One-Shot Arguments of a Worker]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Sometimes, derived joint-points are just lambda-lifted thunks, whose
only argument is of the unit type and is never used. This might
interfere with the absence analysis, basing on which results these
never-used arguments are eliminated in the worker. The additional
argument `all_one_shot` of `mkWorkerArgs` is to prevent this.

An example for this phenomenon is a `treejoin` program from the
`nofib` suite, which features the following joint points:

$j_s1l1 =
  \ _ ->
     case GHC.Prim.<=# 56320 y_aOy of _ {
        GHC.Types.False -> $j_s1kP GHC.Prim.realWorld#;
        GHC.Types.True ->  ... }

%************************************************************************
%*									*
\subsection{Coercion stuff}
%*									*
%************************************************************************

We really want to "look through" coerces.
Reason: I've seen this situation:

	let f = coerce T (\s -> E)
	in \x -> case x of
	   	    p -> coerce T' f
		    q -> \s -> E2
	   	    r -> coerce T' f

If only we w/w'd f, we'd get
	let f = coerce T (\s -> fw s)
	    fw = \s -> E
	in ...

Now we'll inline f to get

	let fw = \s -> E
	in \x -> case x of
	   	    p -> fw
		    q -> \s -> E2
	   	    r -> fw

Now we'll see that fw has arity 1, and will arity expand
the \x to get what we want.

\begin{code}
-- mkWWargs just does eta expansion
-- is driven off the function type and arity.
-- It chomps bites off foralls, arrows, newtypes
-- and keeps repeating that until it's satisfied the supplied arity

mkWWargs :: TvSubst		-- Freshening substitution to apply to the type
				--   See Note [Freshen type variables]
	 -> Type		-- The type of the function
	 -> [(Demand,Bool)]	-- Demands and one-shot info for value arguments
	 -> UniqSM  ([Var],		-- Wrapper args
		     CoreExpr -> CoreExpr,	-- Wrapper fn
		     CoreExpr -> CoreExpr,	-- Worker fn
		     Type)			-- Type of wrapper body

mkWWargs subst fun_ty arg_info
  | Just (rep_ty, co) <- splitNewTypeRepCo_maybe fun_ty
   	-- The newtype case is for when the function has
	-- a recursive newtype after the arrow (rare)
	-- We check for arity >= 0 to avoid looping in the case
	-- of a function whose type is, in effect, infinite
	-- [Arity is driven by looking at the term, not just the type.]
	--
	-- It's also important when we have a function returning (say) a pair
	-- wrapped in a recursive newtype, at least if CPR analysis can look 
	-- through such newtypes, which it probably can since they are 
	-- simply coerces.
	--
	-- Note (Sept 08): This case applies even if demands is empty.
	--		   I'm not quite sure why; perhaps it makes it
	--		   easier for CPR
  = do { (wrap_args, wrap_fn_args, work_fn_args, res_ty)
	    <-  mkWWargs subst rep_ty arg_info
 	; return (wrap_args,
	     	  \e -> Cast (wrap_fn_args e) (mkSymCo co),
     		  \e -> work_fn_args (Cast e co),
     		  res_ty) } 

  | null arg_info
  = return ([], id, id, substTy subst fun_ty)

  | Just (tv, fun_ty') <- splitForAllTy_maybe fun_ty
  = do 	{ let (subst', tv') = substTyVarBndr subst tv
		-- This substTyVarBndr clones the type variable when necy
		-- See Note [Freshen type variables]
  	; (wrap_args, wrap_fn_args, work_fn_args, res_ty)
	     <- mkWWargs subst' fun_ty' arg_info
	; return (tv' : wrap_args,
        	  Lam tv' . wrap_fn_args,
        	  work_fn_args . (`App` Type (mkTyVarTy tv')),
        	  res_ty) }

  | ((dmd,one_shot):arg_info') <- arg_info
  , Just (arg_ty, fun_ty') <- splitFunTy_maybe fun_ty
  = do	{ uniq <- getUniqueM
	; let arg_ty' = substTy subst arg_ty
	      id = mk_wrap_arg uniq arg_ty' dmd one_shot
	; (wrap_args, wrap_fn_args, work_fn_args, res_ty)
	      <- mkWWargs subst fun_ty' arg_info'
	; return (id : wrap_args,
	          Lam id . wrap_fn_args,
        	  work_fn_args . (`App` varToCoreExpr id),
        	  res_ty) }

  | otherwise
  = WARN( True, ppr fun_ty )			-- Should not happen: if there is a demand
    return ([], id, id, substTy subst fun_ty) 	-- then there should be a function arrow

applyToVars :: [Var] -> CoreExpr -> CoreExpr
applyToVars vars fn = mkVarApps fn vars

mk_wrap_arg :: Unique -> Type -> Demand -> Bool -> Id
mk_wrap_arg uniq ty dmd one_shot 
  = set_one_shot one_shot (setIdDemandInfo (mkSysLocal (fsLit "w") uniq ty) dmd)
  where
    set_one_shot True  id = setOneShotLambda id
    set_one_shot False id = id
\end{code}

Note [Freshen type variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Wen we do a worker/wrapper split, we must not use shadowed names,
else we'll get
   f = /\ a /\a. fw a a
which is obviously wrong.  Type variables can can in principle shadow,
within a type (e.g. forall a. a -> forall a. a->a).  But type
variables *are* mentioned in <blah>, so we must substitute.

That's why we carry the TvSubst through mkWWargs
	
%************************************************************************
%*									*
\subsection{Strictness stuff}
%*									*
%************************************************************************

\begin{code}
mkWWstr :: DynFlags
        -> [Var]				-- Wrapper args; have their demand info on them
						--  *Includes type variables*
        -> UniqSM ([Var],			-- Worker args
		   CoreExpr -> CoreExpr,	-- Wrapper body, lacking the worker call
						-- and without its lambdas 
						-- This fn adds the unboxing
				
		   CoreExpr -> CoreExpr)	-- Worker body, lacking the original body of the function,
						-- and lacking its lambdas.
						-- This fn does the reboxing
mkWWstr _ []
  = return ([], nop_fn, nop_fn)

mkWWstr dflags (arg : args) = do
    (args1, wrap_fn1, work_fn1) <- mkWWstr_one dflags arg
    (args2, wrap_fn2, work_fn2) <- mkWWstr dflags args
    return (args1 ++ args2, wrap_fn1 . wrap_fn2, work_fn1 . work_fn2)

\end{code}

Note [Unpacking arguments with product and polymorphic demands]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The argument is unpacked in a case if it has a product type and has a
strict *and* used demand put on it. I.e., arguments, with demands such
as the following ones:

   <S,U(U, L)>
   <S(L,S),U>

will be unpacked, but

   <S,U> or <B,U>

will not, because the pieces aren't used. This is quite important otherwise
we end up unpacking massive tuples passed to the bottoming function. Example:

 	f :: ((Int,Int) -> String) -> (Int,Int) -> a
 	f g pr = error (g pr)

 	main = print (f fst (1, error "no"))

Does 'main' print "error 1" or "error no"?  We don't really want 'f'
to unbox its second argument.  This actually happened in GHC's onwn
source code, in Packages.applyPackageFlag, which ended up un-boxing
the enormous DynFlags tuple, and being strict in the
as-yet-un-filled-in pkgState files.

\begin{code}
----------------------
-- mkWWstr_one wrap_arg = (work_args, wrap_fn, work_fn)
--   *  wrap_fn assumes wrap_arg is in scope,
--	  brings into scope work_args (via cases)
--   * work_fn assumes work_args are in scope, a
--	  brings into scope wrap_arg (via lets)
mkWWstr_one :: DynFlags -> Var -> UniqSM ([Var], CoreExpr -> CoreExpr, CoreExpr -> CoreExpr)
mkWWstr_one dflags arg
  | isTyVar arg
  = return ([arg],  nop_fn, nop_fn)

  | isAbsDmd dmd
  , Just work_fn <- mk_absent_let dflags arg
     -- Absent case.  We can't always handle absence for arbitrary
     -- unlifted types, so we need to choose just the cases we can
     --- (that's what mk_absent_let does)
  = return ([], nop_fn, work_fn)
      
  | isSeqDmd dmd  -- `seq` demand; evaluate in wrapper in the hope
                  -- of dropping seqs in the worker
  = let arg_w_unf = arg `setIdUnfolding` evaldUnfolding
	  -- Tell the worker arg that it's sure to be evaluated
          -- so that internal seqs can be dropped
    in return ([arg_w_unf], mk_seq_case arg, nop_fn)
	  	-- Pass the arg, anyway, even if it is in theory discarded
		-- Consider
		--	f x y = x `seq` y
		-- x gets a (Eval (Poly Abs)) demand, but if we fail to pass it to the worker
		-- we ABSOLUTELY MUST record that x is evaluated in the wrapper.
		-- Something like:
		--	f x y = x `seq` fw y
		--	fw y = let x{Evald} = error "oops" in (x `seq` y)
		-- If we don't pin on the "Evald" flag, the seq doesn't disappear, and
		-- we end up evaluating the absent thunk.
		-- But the Evald flag is pretty weird, and I worry that it might disappear
		-- during simplification, so for now I've just nuked this whole case

  | isStrictDmd dmd
  , Just cs <- splitProdDmd_maybe dmd
      -- See Note [Unpacking arguments with product and polymorphic demands]
  , Just (data_con, inst_tys, inst_con_arg_tys, co) 
             <- deepSplitProductType_maybe (idType arg)
  =  do { (uniq1:uniqs) <- getUniquesM
	; let   unpk_args      = zipWith mk_ww_local uniqs inst_con_arg_tys
	        unpk_args_w_ds = zipWithEqual "mkWWstr" set_worker_arg_info unpk_args cs
	        unbox_fn       = mkUnpackCase (Var arg `mkCast` co) uniq1
                                              data_con unpk_args
	        rebox_fn       = Let (NonRec arg con_app) 
	        con_app        = mkConApp2 data_con inst_tys unpk_args `mkCast` mkSymCo co
	 ; (worker_args, wrap_fn, work_fn) <- mkWWstr dflags unpk_args_w_ds
	 ; return (worker_args, unbox_fn . wrap_fn, work_fn . rebox_fn) }
	  		   -- Don't pass the arg, rebox instead
			
  | otherwise	-- Other cases
  = return ([arg], nop_fn, nop_fn)

  where
    dmd = idDemandInfo arg
	-- If the wrapper argument is a one-shot lambda, then
	-- so should (all) the corresponding worker arguments be
	-- This bites when we do w/w on a case join point
    set_worker_arg_info worker_arg demand = set_one_shot (setIdDemandInfo worker_arg demand)

    set_one_shot | isOneShotLambda arg = setOneShotLambda
		 | otherwise	       = \x -> x

----------------------
nop_fn :: CoreExpr -> CoreExpr
nop_fn body = body
\end{code}

\begin{code}
deepSplitProductType_maybe :: Type -> Maybe (DataCon, [Type], [Type], Coercion)
-- If    deepSplitProductType_maybe ty = Just (dc, tys, arg_tys, co)
-- then  dc @ tys (args::arg_tys)  |> co :: ty
deepSplitProductType_maybe ty
  | let (ty1, co) = topNormaliseNewType ty `orElse` (ty, mkReflCo ty)
  , Just (tc, tc_args) <- splitTyConApp_maybe ty1
  , Just con <- isDataProductTyCon_maybe tc
  = Just (con, tc_args, dataConInstArgTys con tc_args, co)
deepSplitProductType_maybe _ = Nothing

deepSplitCprType_maybe :: ConTag -> Type -> Maybe (DataCon, [Type], [Type], Coercion)
deepSplitCprType_maybe con_tag ty
  | let (ty1, co) = topNormaliseNewType ty `orElse` (ty, mkReflCo ty)
  , Just (tc, tc_args) <- splitTyConApp_maybe ty1
  , isDataTyCon tc
  , let cons = tyConDataCons tc
        con = ASSERT( cons `lengthAtLeast` con_tag ) cons !! (con_tag - fIRST_TAG)
  = Just (con, tc_args, dataConInstArgTys con tc_args, co)
deepSplitCprType_maybe _ _ = Nothing
\end{code}


%************************************************************************
%*									*
\subsection{CPR stuff}
%*									*
%************************************************************************


@mkWWcpr@ takes the worker/wrapper pair produced from the strictness
info and adds in the CPR transformation.  The worker returns an
unboxed tuple containing non-CPR components.  The wrapper takes this
tuple and re-produces the correct structured output.

The non-CPR results appear ordered in the unboxed tuple as if by a
left-to-right traversal of the result structure.


\begin{code}
mkWWcpr :: Type                              -- function body type
        -> DmdResult                         -- CPR analysis results
        -> UniqSM (CoreExpr -> CoreExpr,             -- New wrapper 
                   CoreExpr -> CoreExpr,	     -- New worker
		   Type)			-- Type of worker's body 

mkWWcpr body_ty res
  = case returnsCPR_maybe res of
       Nothing      -> return (id, id, body_ty)  -- No CPR info
       Just con_tag | Just stuff <- deepSplitCprType_maybe con_tag body_ty
                    -> mkWWcpr_help stuff
                    |  otherwise
                    -> WARN( True, text "mkWWcpr: non-algebraic or open body type" <+> ppr body_ty )
                       return (id, id, body_ty)
          
mkWWcpr_help :: (DataCon, [Type], [Type], Coercion)
             -> UniqSM (CoreExpr -> CoreExpr, CoreExpr -> CoreExpr, Type)

mkWWcpr_help (data_con, inst_tys, arg_tys, co)
  | [arg_ty1] <- arg_tys
  , isUnLiftedType arg_ty1
	-- Special case when there is a single result of unlifted type
	--
	-- Wrapper:	case (..call worker..) of x -> C x
	-- Worker:	case (   ..body..    ) of C x -> x
  = do { (work_uniq : arg_uniq : _) <- getUniquesM
       ; let arg       = mk_ww_local arg_uniq  arg_ty1
	     con_app   = mkConApp2 data_con inst_tys [arg] `mkCast` co

       ; return ( \ wkr_call -> Case wkr_call arg (exprType con_app) [(DEFAULT, [], con_app)]
                , \ body     -> mkUnpackCase body work_uniq data_con [arg] (Var arg)
                , arg_ty1 ) }

  | otherwise 	-- The general case
	-- Wrapper: case (..call worker..) of (# a, b #) -> C a b
	-- Worker:  case (   ...body...  ) of C a b -> (# a, b #)     
  = do { (work_uniq : uniqs) <- getUniquesM
       ; let (wrap_wild : args) = zipWith mk_ww_local uniqs (ubx_tup_ty : arg_tys)
	     ubx_tup_con  = tupleCon UnboxedTuple (length arg_tys)
	     ubx_tup_ty	  = exprType ubx_tup_app
	     ubx_tup_app  = mkConApp2 ubx_tup_con arg_tys args
             con_app	  = mkConApp2 data_con inst_tys args `mkCast` co

       ; return ( \ wkr_call -> Case wkr_call wrap_wild (exprType con_app)  [(DataAlt ubx_tup_con, args, con_app)]
		, \ body     -> mkUnpackCase body work_uniq data_con args ubx_tup_app
		, ubx_tup_ty ) }

mkUnpackCase ::  CoreExpr -> Unique -> DataCon -> [Id] -> CoreExpr -> CoreExpr
-- (mkUnpackCase e bndr Con args body)
--      returns
-- case e of bndr { Con args -> body }
-- 
-- the type of the bndr passed in is irrelevent

mkUnpackCase (Tick tickish e) uniq con args body   -- See Note [Profiling and unpacking]
  = Tick tickish (mkUnpackCase e uniq con args body)
mkUnpackCase scrut uniq boxing_con unpk_args body
  = Case scrut 
         (mk_ww_local uniq (exprType scrut)) (exprType body) 
         [(DataAlt boxing_con, unpk_args, body)]
\end{code}

Note [Profiling and unpacking]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If the original function looked like
	f = \ x -> _scc_ "foo" E

then we want the CPR'd worker to look like
	\ x -> _scc_ "foo" (case E of I# x -> x)
and definitely not
	\ x -> case (_scc_ "foo" E) of I# x -> x)

This transform doesn't move work or allocation
from one cost centre to another.

Later [SDM]: presumably this is because we want the simplifier to
eliminate the case, and the scc would get in the way?  I'm ok with
including the case itself in the cost centre, since it is morally
part of the function (post transformation) anyway.


%************************************************************************
%*									*
\subsection{Utilities}
%*									*
%************************************************************************

Note [Absent errors]
~~~~~~~~~~~~~~~~~~~~
We make a new binding for Ids that are marked absent, thus
   let x = absentError "x :: Int"
The idea is that this binding will never be used; but if it 
buggily is used we'll get a runtime error message.

Coping with absence for *unlifted* types is important; see, for
example, Trac #4306.  For these we find a suitable literal,
using Literal.absentLiteralOf.  We don't have literals for
every primitive type, so the function is partial.

    [I did try the experiment of using an error thunk for unlifted
    things too, relying on the simplifier to drop it as dead code,
    by making absentError 
      (a) *not* be a bottoming Id, 
      (b) be "ok for speculation"
    But that relies on the simplifier finding that it really
    is dead code, which is fragile, and indeed failed when 
    profiling is on, which disables various optimisations.  So
    using a literal will do.]

\begin{code}
mk_absent_let :: DynFlags -> Id -> Maybe (CoreExpr -> CoreExpr)
mk_absent_let dflags arg
  | not (isUnLiftedType arg_ty)
  = Just (Let (NonRec arg abs_rhs))
  | Just tc <- tyConAppTyCon_maybe arg_ty
  , Just lit <- absentLiteralOf tc
  = Just (Let (NonRec arg (Lit lit)))
  | arg_ty `eqType` realWorldStatePrimTy 
  = Just (Let (NonRec arg (Var realWorldPrimId)))
  | otherwise
  = WARN( True, ptext (sLit "No absent value for") <+> ppr arg_ty )
    Nothing
  where
    arg_ty  = idType arg
    abs_rhs = mkRuntimeErrorApp aBSENT_ERROR_ID arg_ty msg
    msg     = showSDocDebug dflags (ppr arg <+> ppr (idType arg))

mk_seq_case :: Id -> CoreExpr -> CoreExpr
mk_seq_case arg body = Case (Var arg) (sanitiseCaseBndr arg) (exprType body) [(DEFAULT, [], body)]

sanitiseCaseBndr :: Id -> Id
-- The argument we are scrutinising has the right type to be
-- a case binder, so it's convenient to re-use it for that purpose.
-- But we *must* throw away all its IdInfo.  In particular, the argument
-- will have demand info on it, and that demand info may be incorrect for
-- the case binder.  e.g.  	case ww_arg of ww_arg { I# x -> ... }
-- Quite likely ww_arg isn't used in '...'.  The case may get discarded
-- if the case binder says "I'm demanded".  This happened in a situation 
-- like		(x+y) `seq` ....
sanitiseCaseBndr id = id `setIdInfo` vanillaIdInfo

mk_ww_local :: Unique -> Type -> Id
mk_ww_local uniq ty = mkSysLocal (fsLit "ww") uniq ty
\end{code}
