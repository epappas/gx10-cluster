;; extends
;;
;; Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
;;
;; Fold a RUN of consecutive comments as one fold. Every language's own
;; folds.scm already folds the structural nodes - a YAML block, an if/else, a
;; function body - and none of the ones this box compiles folds comments, so
;; a forty-line header block could not be collapsed at all.
;;
;; `extends` ADDS to the language's query rather than replacing it, so the
;; structural folds above are untouched.
;;
;; The `+` is what makes this a block rather than per-line noise: it matches a
;; run of adjacent comment siblings and folds the run. A single-line comment
;; spans one line and so produces no fold, which is the wanted behaviour.
;;
;; Deliberately NO (#trim! @fold). It parses, and it silently breaks the whole
;; folds query for the language - every fold level in the buffer drops to 0,
;; including the structural ones that worked before. Verified on yaml.
;;
;; This file is installed per language by roles/editor, for the languages in
;; nvim_comment_fold_languages. It is NOT installed for go or rust: both of
;; their folds.scm capture the function AND its block over the same range, so
;; a comment fold above them never closes and swallows the function that
;; follows. Verified: closing the comment fold hid the whole file.
([
  (comment)
]+ @fold)
