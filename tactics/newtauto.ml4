(***********************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team    *)
(* <O___,, *        INRIA-Rocquencourt  &  LRI-CNRS-Orsay              *)
(*   \VV/  *************************************************************)
(*    //   *      This file is distributed under the terms of the      *)
(*         *       GNU Lesser General Public License Version 2.1       *)
(***********************************************************************)

(*i camlp4deps: "parsing/grammar.cma" i*)

(*i $Id$ i*)

open Ast
open Coqast
open Hipattern
open Names
open Libnames
open Pp
open Proof_type
open Tacticals
open Tacinterp
open Tactics
open Tacexpr
open Util
open Term
open Termops
open Declarations

let myprint env rc t=
	let env2=Environ.push_rel_context rc env in
	let ppstr=Printer.prterm_env env2 t in
	Pp.msgnl ppstr

let tacinj tac=valueIn (VTactic (dummy_loc,tac))

let tclATMOSTn n tac1 gl=
  let result=tac1 gl in
    if List.length (fst result).it <= n then result
    else (tclFAIL 0 "Not enough subgoals" gl)

let tclTRY_REV_HYPS (tac : constr->tactic) gl = 
  tclTRY_sign tac (List.rev (Tacmach.pf_hyps gl)) gl
 
let rec nb_prod_after n c=
  match kind_of_term c with
    | Prod (_,_,b) ->if n>0 then nb_prod_after (n-1) b else 
	1+(nb_prod_after 0 b)
    | _            -> 0

let nhyps ind = 
  let (mib,mip) = Global.lookup_inductive ind in
  let constr_types = mip.mind_nf_lc in 
  let nhyps = nb_prod_after mip.mind_nparams in	
    Array.map nhyps constr_types

let isrec ind=
  let (mib,mip) = Global.lookup_inductive ind in
  Inductiveops.mis_is_recursive (ind,mib,mip)

let simplif=Tauto.reduction_not_iff

let rule_axiom=assumption
		      
let rule_rforall tac=tclTHEN intro tac

let rule_rarrow=interp  <:tactic<Match Reverse Context With
      | [|- ?1 -> ?2 ] -> Intro>>

let rule_larrow= 
  (interp <:tactic<(Match Reverse Context With 
			    [f:?1->?2;x:?1|-?] ->
			      Generalize (f x);Clear f;Intro)>>)

let rule_simp_larrow tac=
  let itac=tacinj tac in
  (interp <:tactic<(Match Reverse Context With 
			    [f:?1->?2|-?] ->
			      Assert ?1;[Solve $itac|IdTac])>>)


let rule_named_llarrow id gl=
    (try let nam=destVar id in
    let body=Tacmach.pf_get_hyp_typ gl nam in
    let (_,cc,c)=destProd body in
    if dependent (mkRel 1) c then tclFAIL 0 "" else
    let (_,ta,b)=destProd cc in
    if dependent (mkRel 1) b then tclFAIL 0 "" else 
    let tb=pop b and tc=pop c in
    let d=mkLambda (Anonymous,tb,
    mkApp (id,[|mkLambda (Anonymous,(lift 1 ta),(mkRel 2))|])) in
    let env=Tacmach.pf_env gl in
      tclTHENS (cut tc)
	[tclTHEN intro (clear [nam]);
	 tclTHENS (cut cc) 
	   [exact_check id; tclTHENLIST [generalize [d];intro;clear [nam]]]]
   with Invalid_argument _ -> tclFAIL 0 "") gl

let rule_llarrow tac=
  tclTRY_REV_HYPS 
    (fun id->tclTHENS (rule_named_llarrow id) [tclIDTAC;tac])
		       (* this rule always increases the number of goals*)

let rule_rind tac gl=
  (let (hdapp,args)=decompose_app gl.it.Evd.evar_concl in
     try let ind=destInd hdapp in
       if isrec ind then tclFAIL 0 "Found a recursive inductive type" else
	 any_constructor (Some tac)
     with Invalid_argument _ -> tclFAIL 0 "") gl 
  
let rule_rind_rev (* b *) gl=  
  (let (hdapp,args)=decompose_app gl.it.Evd.evar_concl in
     try let ind=destInd hdapp in
       if (isrec ind)(* || (not b && (nhyps ind).(0)>1) *) then
	 tclFAIL 0 "Found a recursive inductive type"
       else
	 simplest_split
     with Invalid_argument _ -> tclFAIL 0 "") gl 
  (* this rule increases the number of goals 
if the unique constructor has several hyps.
i.e if (nhyps ind).(0)>1 *)

let rule_named_false id gl=
  (try let nam=destVar id in
   let body=Tacmach.pf_get_hyp_typ gl nam in
     if is_empty_type body then (simplest_elim id)
     else tclFAIL 0 "Found an non empty type"
   with Invalid_argument _ -> tclFAIL 0 "") gl

let rule_false=tclTRY_REV_HYPS rule_named_false

let rule_named_lind (*b*) id gl= 
  (try let nam=destVar id in
   let body=Tacmach.pf_get_hyp_typ gl nam in
   let (hdapp,args) = decompose_app body in
   let ind=destInd hdapp in
   (*let nconstr=
    if b then 0 else 
      Array.length (snd (Global.lookup_inductive ind)).mind_consnames in *)
     if (isrec ind) (*|| (nconstr>1)*) then 
       tclFAIL 0 "Found a recursive inductive type"
     else 
       let l=nhyps ind in
       let f n= tclDO n intro in
	 tclTHENSV (tclTHEN (simplest_elim id) (clear [nam])) (Array.map f l)
   with Invalid_argument _ -> tclFAIL 0 "") gl
  
let rule_lind (* b *) =
  tclTRY_REV_HYPS (rule_named_lind (* b *))
(* number of goals increases if ind has several constructors *)

let rule_named_llind id gl= 
    (try let nam=destVar id in 
    let body=Tacmach.pf_get_hyp_typ gl nam in
    let (_,xind,b) =destProd body in
    if dependent (mkRel 1) b then tclFAIL 0 "Found a dependent product" else  
    let (hdapp,args) = decompose_app xind in
    let vargs=Array.of_list args in
    let ind=destInd hdapp in
    if isrec ind then tclFAIL 0 "" else
    let (mib,mip) = Global.lookup_inductive ind in
    let n=mip.mind_nparams in
    if n<>(List.length args) then tclFAIL 0 "" else
    let p=nhyps ind in
    let types= mip.mind_nf_lc in
    let names= mip.mind_consnames in

	(* construire le terme  H->B, le generaliser etc *)   
    let myterm i=
	let env=Tacmach.pf_env gl and emap=Tacmach.project gl in
	let t1=Reductionops.hnf_prod_appvect env emap types.(i) vargs in
	let (rc,_)=Sign.decompose_prod_n_assum p.(i) t1 in
	let cstr=mkApp ((mkConstruct (ind,(i+1))),vargs) in
	let vars=Array.init p.(i) (fun j->mkRel (p.(i)-j)) in
	let capply=mkApp ((lift p.(i) cstr),vars) in
	let head=mkApp ((lift p.(i) id),[|capply|]) in
	Sign.it_mkLambda_or_LetIn head rc in
	
    let newhyps=List.map myterm (interval 0 ((Array.length p)-1)) in
     tclTHEN (generalize newhyps)
	(tclTHEN (clear [nam]) (tclDO (Array.length p) intro))
	with Invalid_argument _ ->tclFAIL 0 "") gl

let rule_llind=tclTRY_REV_HYPS rule_named_llind

let default_stac = interp(<:tactic< Auto with * >>)

let rec newtauto b stac gl=
  let wrap tac=if b then tac else 
    tclATMOSTn 1 (tclTHEN tac (tclSOLVE [stac])) in
    (tclTHEN simplif 
       (tclORELSE 
	  (tclTHEN 
	     (tclFIRST [
		rule_axiom;
		rule_false;
		rule_rarrow;
		wrap rule_lind; 
		rule_larrow;
		rule_llind;
		wrap rule_rind_rev; 
		rule_llarrow (tclSOLVE [newtauto b stac]);
		rule_rind (tclSOLVE [newtauto b stac]);
		rule_rforall (tclSOLVE [newtauto b stac]);
		if b then tclFAIL 0 "" else (rule_simp_larrow stac)])
		(tclPROGRESS (newtauto b stac)))
		stac)) gl
 
let q_elim tac=
  let vtac=Tacexpr.TacArg (valueIn (VTactic (dummy_loc,tac))) in	
  interp <:tactic<
  Match Context With 
    [x:?1;H:?1->?|-?]->
      Generalize (H x);Clear H;$vtac>>

let rec lfo n=
  if n=0 then (tclFAIL 0 "NewLinearIntuition failed") else
    let p=if n<0 then n else (n-1) in
    let lfo_rec=q_elim (fun gl->lfo p gl) in
      newtauto true lfo_rec

let lfo_wrap n gl= 
  try lfo n gl
  with
    Refiner.FailError _ | UserError _ ->
      errorlabstrm "NewLinearIntuition" [< str "NewLinearIntuition failed." >]

TACTIC EXTEND NewIntuition
      [ "NewIntuition" ] -> [ newtauto true default_stac ]
      |[ "NewIntuition" tactic(t)] -> [ newtauto true (interp t) ]
END

TACTIC EXTEND Intuition1
      [ "Intuition1" ] -> [ newtauto false default_stac ]
      |[ "Intuition1" tactic(t)] -> [ newtauto false (interp t) ]
END

TACTIC EXTEND NewTauto
  [ "NewTauto" ] -> [ newtauto true (tclFAIL 0 "NewTauto failed") ]
END

TACTIC EXTEND NewLinearIntuition
  [ "NewLinearIntuition" ] -> [ lfo_wrap (-1) ]
|  [ "NewLinearIntuition" integer(n)] -> [ lfo_wrap n ]
END

