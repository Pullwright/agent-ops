## Acceptance checks

### Acceptance checks — continued (part 8 of 9; items 11e–11e)

11e. <a id="impl-ac-11e"></a>**A human's own label is read back, and only where this mechanism put it
    (requirement 34g).** `test/needs-refinement.test.sh` passes:
    `refinement_hand_flag_new` turns a labelled, open issue with no existing
    block — of any kind — into a fresh entry, and reports nothing for one
    already blocked (no duplicate for the same label on the same item) or for
    a labelled issue that is closed; `refinement_hand_flag_fields` marks what
    it builds `hand_flagged: true` with no `unblock_condition`;
    `refinement_hand_flag_cleared` maps a `hand_flagged` block whose issue has
    lost the label — open or closed — to an `unblocked` candidate, but leaves
    alone both a block still carrying the label and a block that is not marked
    `hand_flagged` (the Script's own projection from a Co-Ordinator's report),
    even when that one's label is also missing — proving the one-way rule
    requirement 34e states for that population still holds.
