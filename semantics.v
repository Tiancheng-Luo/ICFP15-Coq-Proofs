Require Export heap.       
Require Export Omega.  
Require Export hetList. 
Require Export Coq.Program.Equality. 

(*evaluation context decomposition*)
Inductive decompose : term -> ctxt -> term -> Prop :=
|decompApp : forall e1 e2 E e, decompose e1 E e ->
                               decompose (app e1 e2) (appCtxt e2 E) e
|decompAppVal : forall v e2 E e (prf:value v), 
                  decompose e2 E e -> decompose (app v e2) (appValCtxt v prf E) e
|appHole : forall e v, value v -> decompose (app (lambda e) v) hole (app (lambda e) v)
|decompGet : forall e E e', decompose e E e' -> 
                            decompose (get e) (getCtxt E) e'
|decompGetHole : forall l, decompose (get (loc l)) hole (get (loc l))
|decompPut : forall e1 e2 E e, decompose e1 E e -> 
                               decompose (put e1 e2) (putCtxt e2 E) e
|decompPutVal : forall v e2 E e (prf:value v), 
                  decompose e2 E e -> 
                  decompose (put v e2) (putValCtxt v prf E) e
|decompPutHole : forall n v, value v -> decompose (put (loc n) v) hole (put (loc n) v)
|decompAlloc : forall e E e', decompose e E e' ->
                              decompose (alloc e) (allocCtxt E) e'
|decompAllocHole : forall v, value v -> decompose (alloc v) hole (alloc v)
|decompAtomicHole : forall e, decompose (atomic e) hole (atomic e)
|decompFork : forall e, decompose (fork e) hole (fork e)
|decompInAtomic : forall e e' E, decompose e E e' ->
                            decompose (inatomic e) (inatomicCtxt E) e'
|decompInAtomicHole : forall v, value v -> decompose (inatomic v) hole (inatomic v). 

(*values cannot be decomposed*)
Theorem decomposeValFalse : forall t E e, value t -> decompose t E e -> False. 
Proof.
  intros t E e v d. inv d; try solve[inv v]. 
Qed. 

(*proves that values cannot be decomposed*)
Ltac decompVal :=
  match goal with
      |H:value ?t, H':decompose ?t ?E ?e |- _ => 
       apply decomposeValFalse in H'; auto; inv H'
      |H:decompose (lambda ?e) ?E ?e' |- _ => inv H
      |H:decompose (loc ?l) ?E ?e |- _ => inv H
  end. 

(*inverts a decomposition nested inside another*)
Ltac invertDecomp := 
  match goal with
      |H:decompose (app ?e1 ?e2) ?E ?e |- _ => inv H
      |H:decompose (get ?e) ?E ?e' |- _ => inv H
      |H:decompose (put ?e1 ?e2) ?E ?e |- _ => inv H
      |H:decompose (alloc ?e) ?E ?e' |- _ => inv H
      |H:decompose (fork ?e) ?E ?e' |- _ => inv H
      |H:decompose (inatomic ?e) ?E ?E' |- _ => inv H
  end. 

(*evaluation context decomposition is deterministic*)
Theorem decomposeDeterministic : forall t E E' e e', 
                                   decompose t E e -> decompose t E' e' ->
                                   E = E' /\ e = e'. 
Proof.
  intros t E E' e e' HD1 HD2. genDeps {{ E'; e'}}. 
  induction HD1; intros; try(invertDecomp; try decompVal); try solve[auto |
  match goal with
    |H:forall e'0 E', decompose ?e E' e'0 -> ?E = E' /\ ?e' = e'0, 
     H':decompose ?e ?E'' ?e'' |- _ =>  apply H in H'; invertHyp; eauto; try (proofsEq; eauto)
  end]. 
  inv HD2. eauto. 
Qed. 
 
(*proves that the results of the same decomposition are the same*)
Ltac decompSame :=
  match goal with
      |H:decompose ?t ?E ?e,H':decompose ?t ?E' ?e' |- _ =>
       eapply decomposeDeterministic in H; eauto; invertHyp
  end.  

(*fill an evaluation context*)
Fixpoint fill (E:ctxt) (e:term) := 
  match E with
      |appCtxt e' E => app (fill E e) e'
      |appValCtxt v _ E => app v (fill E e)
      |getCtxt E => get (fill E e)
      |putCtxt e' E => put (fill E e) e'
      |putValCtxt v _ E => put v (fill E e)
      |allocCtxt E => alloc (fill E e)
      |inatomicCtxt E => inatomic (fill E e)
      |hole => e 
  end.

(*
commit H ==> indicates the log is valid and H contains the new writes from the log
abort e L ==> log was invalid, resume execution at term e with log L
*)
Inductive validateRes : Type := 
|commit : validateRes
|abort : term -> read_set -> validateRes. 

Inductive invalidStamp : nat -> lock -> Prop :=
| StampStale : forall s s', s < s' -> invalidStamp s (Unlocked s')
| StampLocked : forall s s', invalidStamp s (Locked s'). 

Inductive validStamp : nat -> lock -> Prop :=
| LockOwned : forall s, validStamp s (Locked s)
| StampFresh : forall s s', s > s' -> validStamp s (Unlocked s').

(* Transactional log validation
 * Validate RV L H WV Res
 * RV - read version
 * RS - read set
 * H - heap
 * WV - write version
 * Res - result of validation, either:
 *    + commit - validation succeeded
 *    + abort e L - abort, picking up with term `e` and log `L`
 *)
Inductive validate : stamp -> read_set -> heap -> validateRes -> Prop :=
|validateNil : forall S H, validate S nil H commit
|validateRead : forall S lock l v E H L,
                        lookup H l = Some(v, lock) -> validStamp S lock -> 
                        validate S L H commit ->
                        validate S ((l, E, v)::L) H commit
|validateAbortPropogate : forall S L H x L' e, 
                            validate S L H (abort e L') ->
                            validate S (x::L) H (abort e L')
|validateAbortRead : forall S lock H L E l v v',
              validate S L H commit -> lookup H l = Some(v, lock) ->
              invalidStamp S lock ->
              validate S ((l, E, v')::L) H
                       (abort (fill E(get(loc l))) L). 

Fixpoint open (e:term) (k:nat) (e':term) :=
  match e with
      |lambda e => lambda (open e (S k) e')
      |loc l => loc l
      |unit => unit
      |var k' => if eq_nat_dec k k'
                then e'
                else var k'
      |app e1 e2 => app (open e1 k e') (open e2 k e')
      |get e => get (open e k e')
      |put e1 e2 => put (open e1 k e') (open e2 k e')
      |alloc e => alloc (open e k e')
      |fork e => fork (open e k e')
      |atomic e => atomic (open e k e')
      |inatomic e => inatomic (open e k e')
  end. 

(*transactional step (used by both p_step and f_step)*) 
Inductive trans_step (H:heap) : thread -> thread -> Prop :=
(*read after write*)
|t_readStep : forall S RS WS E l t v e0 lock, 
                decompose t E (get (loc l)) -> 
                lookup H l = Some(v, lock) -> validStamp S lock ->
                trans_step H (Some(S, e0), RS, WS, t) 
                             (Some(S, e0), (l, E, v)::RS, WS, fill E v)
(*|t_writeStep : forall S L E l v t,
               decompose t E (put (loc l) v) -> S <> None ->
               trans_step H (S, L, t) (S, writeItem l v::L, fill E unit)
*)
|t_atomicIdemStep : forall E e t RS WS S,
                     decompose t E (atomic e) -> S <> None ->
                     trans_step H (S, RS, WS, t) (S, RS, WS, fill E e)
|t_betaStep : forall RS WS E e t v S, 
              decompose t E (app (lambda e) v) -> S <> None ->
              trans_step H (S, RS, WS, t) (S, RS, WS, fill E (open e 0 v))
.

(*
(*same as trans_step with addition of r_readStepInvalid*)
Inductive replay_step H : thread -> thread -> Prop :=
|r_readStepValid : forall S L E l t v e0 S', 
                lookup H l = Some(v, S') -> S > S' ->
                decompose t E (get (loc l)) -> logLookup L l = None ->
                replay_step H (Some(S, e0), L, t) (Some(S, e0), readItem l E v::L, fill E v)
|r_readStepInvalid : forall S L E v' l t v e0 S', 
                lookup H l = Some(v',S') -> S' >= S ->
                decompose t E (get (loc l)) -> logLookup L l = None ->
                replay_step H (Some(S, e0), L, t) (Some(S, e0), readItem l E v::L, fill E v)
|r_readInDomainStep : forall S l v L E t e0,
                      decompose t E (get (loc l)) -> logLookup L l = Some v ->
                      replay_step H (Some(S, e0), L, t) (Some(S, e0), L, fill E v)
|r_writeStep : forall S L E l v t,
               decompose t E (put (loc l) v) -> S <> None ->
               replay_step H (S, L, t) (S, writeItem l v::L, fill E unit)
|r_atomicIdemStep : forall E e t L S,
                     decompose t E (atomic e) -> S <> None ->
                     replay_step H (S, L, t) (S, L, fill E e)
|r_betaStep : forall L E e t v S, 
              decompose t E (app (lambda e) v) -> S <> None ->
              replay_step H (S, L, t) (S, L, fill E (open e 0 v))
.

(*reflexive transitive closure of replay_step*)
Inductive replay H : thread -> thread -> Prop :=
|replayRefl : forall t, replay H t t
|replayStep : forall t t' t'', 
                replay_step H t t' -> replay H t' t'' -> 
                replay H t t''. 

(*left recursive version of replay*)
Inductive rewind H : thread -> thread -> Prop :=
|rewindRefl : forall t, rewind H t t
|rewindStep : forall t t' t'', 
                rewind H t t' -> replay_step H t' t'' -> 
                rewind H t t''. 
 *)

(*
 * writeback WS H H'
 * WS - write set
 * H - initial heap
 * WV - write version
 * H' - Updated heap with WS's effects and locks released
 *)
Inductive writeback (wv : nat) : write_set -> heap -> heap -> Prop :=
|WBNil : forall H, writeback wv nil H H
|WBCons : forall v' l v WS H H'' S,
            lookup H l = Some(v, Locked S) ->
            writeback wv WS (update H l v (Unlocked wv)) H'' ->
            writeback wv ((l, v')::WS) H H''
. 

Definition step_sig := nat -> heap -> pool -> nat -> heap -> pool -> Prop. 

(*common steps (single step)*)
Inductive c_step (st : step_sig) : step_sig :=
|c_liftedStep : forall C H P C' H' P',
                  st C H P C' H' P' ->
                  c_step st C H P C' H' P'
|c_transStep : forall C H t t', trans_step H t t' -> 
                           c_step st C H (Single t) C H (Single t')
|c_parLStep : forall C H T1 T2 C' H' T1', 
          c_step st C H T1 C' H' T1' -> c_step st C H (Par T1 T2) C' H' (Par T1' T2)
|c_parRStep : forall C H T1 T2 C' H' T2', 
          c_step st C H T2 C' H' T2' -> c_step st C H (Par T1 T2) C' H' (Par T1 T2')
|c_forkStep : forall C H E e t, 
              decompose t E (fork e) ->
              c_step st C H (Single(None, nil, nil, t)) C H 
                   (Par (Single(None, nil, nil, fill E unit)) (Single(None, nil, nil, e)))
|c_allocStep : forall C H v E t l, 
               lookup H l = None -> decompose t E (alloc v) ->
               c_step st C H (Single(None, nil, nil, t)) (plus 1 C) ((l, v, Unlocked 0)::H)
                    (Single(None, nil, nil, fill E (loc l)))
|c_commitStep : forall C H S RS WS v t E H' e0, 
                  validate S RS H commit -> decompose t E (inatomic v) ->
                  writeback C WS H H' -> 
                  c_step st C H (Single(Some(S, e0), RS, WS, t)) (plus 1 C)
                         H' (Single(None, nil, nil, fill E v))
|c_atomicStep : forall C H E e t, 
                decompose t E (atomic e) ->
                c_step st C H (Single(None, nil, nil, t)) (plus 1 C) H 
                       (Single(Some(C, fill E(inatomic e)),[],[],fill E (inatomic e)))
|c_betaStep : forall C H E e t v, 
              decompose t E (app (lambda e) v) -> 
              c_step st C H (Single(None, nil, nil, t)) C H
                     (Single(None, nil, nil, fill E (open e 0 v))). 

Inductive p_step_ : nat -> heap -> pool -> nat -> heap -> pool -> Prop :=
|p_eagerAbort : forall RS WS S H RS' C e0 e' t v E l lock,
                  lookup H l = Some(v, lock) -> invalidStamp S lock ->
                  validate S ((l, E, v)::RS) H (abort e' RS') ->
                  decompose t E (get (loc l)) -> 
                  p_step_ C H (Single (Some(S, e0), RS, WS, t))
                         (C+1) H (Single(Some(C, e0), RS', nil, e'))
|p_abortStep : forall RS WS S H RS' C e e0 e', 
                 validate S RS H (abort e' RS') ->
                 p_step_ C H (Single(Some(S, e0), RS, WS, e))
                        (plus 1 C) H (Single(Some(C, e0), RS', nil, e'))
.

(*full abort STM semantics (single step)*)
Inductive f_step_ : nat -> heap -> pool -> nat -> heap -> pool -> Prop :=
|f_eagerAbort : forall RS lock WS RS' S H C e0 e' t v E l,
                  lookup H l = Some(v, lock) -> invalidStamp S lock ->
                  validate S ((l, E, v)::RS) H (abort e' RS') ->
                  decompose t E (get (loc l)) -> 
                  f_step_ C H (Single (Some(S, e0), RS, WS, t))
                         (C+1) H (Single(Some(C, e0), nil, nil, e0))
|f_abortStep : forall RS WS RS' S H C e e0 e', 
           validate S RS H (abort e' RS') -> 
           f_step_ C H (Single(Some(S, e0), RS, WS, e)) (plus 1 C) H 
                  (Single(Some(C, e0), nil, nil, e0))
. 

Definition p_step := c_step p_step_.
Definition f_step := c_step f_step_. 

(*reflexive transitive closure of partial multistep*)
Inductive multistep (st : step_sig) : step_sig :=
|c_multi_refl : forall C H T, multistep st C H T C H T
|c_multi_step : forall C H T C' H' T' C'' H'' T'', 
                  st C H T C' H' T' -> multistep st C' H' T' C'' H'' T'' ->
                  multistep st C H T C'' H'' T''. 

Definition f_multistep := multistep f_step.
Definition p_multistep := multistep p_step.

(*reflexivit transitive closure of trans_step*)
Inductive trans_multistep H : thread -> thread -> Prop :=
|trans_refl : forall t, trans_multistep H t t
|trans_multi_step : forall t t' t'', 
                      trans_step H t t' -> trans_multistep H t' t'' ->
                      trans_multistep H t t''. 

(*indicates that L1 is a postfix of L2*)
Definition postfix {A:Type} (L1 L2 : list A) := exists diff, L2 = diff ++ L1. 

(*all threads can rewind to their initial term of a transaction and have
**a stamp number less than the global clock.  The stamp number 
**constraint probably doesn't belong here, but its handy to have*)
(*
Inductive poolRewind C H : pool -> Prop :=
|rewindSingleNoTX : forall e, poolRewind C H (Single(None,nil,e))
|rewindSingleInTX : forall S e0 L e, 
                      rewind H (Some(S,e0),nil,e0) (Some(S,e0),L,e) ->
                      S < C -> poolRewind C H (Single(Some(S,e0),L,e))
|rewindPar : forall T1 T2, poolRewind C H T1 -> poolRewind C H T2 -> poolRewind C H (Par T1 T2). 
 *)
 
(*inject every step in a multistep derivation into a Par*)
Theorem multi_L : forall st C H T1 T2 T1' C' H', 
                      multistep (c_step st) C H T1 C' H' T1' ->
                      multistep (c_step st) C H (Par T1 T2) C' H' (Par T1' T2). 
Proof.
  intros st C H T1 T2 T1' C' H' HYP. induction HYP.
  {constructor. }
  {econstructor. eapply c_parLStep. eassumption. auto. }
Qed. 
  
(*inject every step in a multistep derivation into a Par*)
Theorem multi_R : forall st C H T1 T2 T2' C' H', 
                      multistep (c_step st) C H T2 C' H' T2' ->
                      multistep (c_step st) C H (Par T1 T2) C' H' (Par T1 T2'). 
Proof.
  intros st C H T1 T2 T2' C' H' HYP. induction HYP.
  {constructor. }
  {econstructor. eapply c_parRStep. eassumption. eassumption. }
Qed. 

(*validation is idempotent*)
Theorem validateValidate : forall S L H L' e,  
                             validate S L H (abort e L') ->
                             validate S L' H commit. 
Proof.
  intros S L H L' e HYP. dependent induction HYP; eauto. 
Qed. 

(*the log returned in an abort is a postfix of the initial log*)
Theorem abortLogPostfix : forall S L H L' e, 
                            validate S L H (abort e L') ->
                            postfix L' L. 
Proof.
  intros S L H L' e HYP. remember (abort e L'). induction HYP; try solveByInv. 
  {apply IHHYP in Heqv. unfold postfix in *. invertHyp.  exists (x::x0). auto. }
  {inv Heqv. unfold postfix. exists [(l, E, v')]. auto. }
Qed.

(*filling an evaluation context with the result of a decomposition
**yields the initial term that was decomposed *)
Theorem decomposeEq : forall E t e, decompose t E e -> t = fill E e. 
Proof.
  induction E; intros; try solve[inv H; simpl;erewrite <- IHE; eauto]. 
  {inv H; auto. }
Qed. 

Theorem lengthsEq : forall (A:Type) (x y : list A), x = y -> length x = length y. 
Proof.
  induction x; intros. 
  {destruct y. auto. inv H. }
  {destruct y. inv H. inv H. simpl. apply f_equal. auto. }
Qed. 

(*
(*replay relation is transitive*)
Theorem trans_replay: forall H t t' t'', 
                         replay H t' t'' -> replay H t t' ->
                         replay H t t''. 
Proof.
  intros H t t' t'' HYP1 HYP2. induction HYP2. auto. econstructor. eauto. auto. 
Qed. 

(*rewind relation is transitive*)
Theorem rewindTrans : forall H t t' t'', 
                        rewind H t t' -> rewind H t' t'' ->
                        rewind H t t''. 
Proof.
  intros H t t' t'' HYP1 HYP2. generalize dependent t. induction HYP2; intros; auto.
  econstructor. eapply IHHYP2. assumption. assumption. 
Qed. 

(*replay and rewind are equivalent*)
Theorem rewindIFFReplay : forall H t t', 
                            rewind H t t' <-> replay H t t'. 
Proof.
  intros H t t'. split; intros HYP. 
  {induction HYP. constructor. eapply trans_replay; eauto.
   econstructor. eauto. constructor. }
  {induction HYP. constructor. eapply rewindTrans; eauto.
   econstructor; eauto. constructor. }
Qed. 
 *)

(*partial multistep relation is transitive*)
Theorem multi_trans : forall st C H T C' H' T' C'' H'' T'',
                          multistep st C H T C' H' T' ->
                          multistep st C' H' T' C'' H'' T'' ->
                          multistep st C H T C'' H'' T''.
Proof.
  intros st C H T C' H' T' C'' H'' T'' HYP1 HYP2. 
  induction HYP1; auto. econstructor; eauto.
Qed. 

