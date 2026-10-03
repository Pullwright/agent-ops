# GitHub API budget report

762 readable reading(s) of 763, from 2026-08-30T10:03:05Z to 2026-08-31T11:58:01Z; 61 primary-limit refusal(s) reached guard-degraded and requirement 2.0 stood a cycle down 15 time(s).

Every figure is the *bucket's*: while every node authenticates as one user (D25
unprovisioned) the `x-ratelimit-*` headers describe the user's aggregate — the
fleet, the dashboard publisher and the owner's shell together — so a segment's
movement is an upper bound on what that segment itself spent.

## Per hour (UTC)

| hour | readings | core peak used | core min remaining | graphql peak used | refusals | budget stand-downs |
|---|---:|---:|---:|---:|---:|---:|
| 2026-08-29T14 | 0 | — | — | — | 12 | 0 |
| 2026-08-29T15 | 0 | — | — | — | 1 | 0 |
| 2026-08-29T16 | 0 | — | — | — | 25 | 0 |
| 2026-08-29T20 | 0 | — | — | — | 5 | 0 |
| 2026-08-30T04 | 0 | — | — | — | 6 | 0 |
| 2026-08-30T06 | 0 | — | — | — | 6 | 0 |
| 2026-08-30T07 | 0 | — | — | — | 6 | 0 |
| 2026-08-30T10 | 11 | 2644 | 2356 | 815 | 0 | 0 |
| 2026-08-30T11 | 2 | 79 | 4921 | 49 | 0 | 0 |
| 2026-08-30T12 | 15 | 4230 | 770 | 1249 | 0 | 0 |
| 2026-08-30T13 | 33 | 4786 | 214 | 1433 | 0 | 0 |
| 2026-08-30T14 | 42 | 5000 | 0 | 1190 | 0 | 2 |
| 2026-08-30T15 | 47 | 5000 | 0 | 991 | 0 | 7 |
| 2026-08-30T16 | 36 | 4166 | 834 | 1181 | 0 | 0 |
| 2026-08-30T17 | 47 | 4803 | 197 | 1539 | 0 | 1 |
| 2026-08-30T18 | 42 | 5000 | 0 | 1803 | 0 | 0 |
| 2026-08-30T19 | 38 | 4065 | 935 | 1327 | 0 | 0 |
| 2026-08-30T20 | 21 | 2353 | 2647 | 700 | 0 | 0 |
| 2026-08-30T21 | 16 | 1425 | 3575 | 460 | 0 | 0 |
| 2026-08-30T22 | 13 | 2334 | 2666 | 698 | 0 | 0 |
| 2026-08-30T23 | 2 | 879 | 4121 | 179 | 0 | 0 |
| 2026-08-31T00 | 20 | 3577 | 1423 | 892 | 0 | 0 |
| 2026-08-31T01 | 33 | 3653 | 1347 | 1128 | 0 | 0 |
| 2026-08-31T02 | 25 | 3612 | 1388 | 1016 | 0 | 0 |
| 2026-08-31T03 | 29 | 3487 | 1513 | 1197 | 0 | 0 |
| 2026-08-31T04 | 35 | 4264 | 736 | 1231 | 0 | 0 |
| 2026-08-31T05 | 47 | 4816 | 184 | 1363 | 0 | 2 |
| 2026-08-31T06 | 48 | 4705 | 295 | 1297 | 0 | 1 |
| 2026-08-31T07 | 44 | 5000 | 0 | 1295 | 0 | 1 |
| 2026-08-31T08 | 40 | 4970 | 30 | 1265 | 0 | 1 |
| 2026-08-31T09 | 40 | 4421 | 579 | 1457 | 0 | 0 |
| 2026-08-31T10 | 12 | 2127 | 2873 | 826 | 0 | 0 |
| 2026-08-31T11 | 25 | 3147 | 1853 | 1283 | 0 | 0 |

## Per stage (bucket movement while the stage ran; window rolls excluded)

| stage | readings | core median | core max | graphql median |
|---|---:|---:|---:|---:|
| approver | 17 | 197 | 919 | 87 |
| coordinator | 164 | 551 | 1952 | 173 |
| coordinator-salvage | 1 | 32 | 32 | 2 |
| enabler | 8 | 178 | 425 | 82 |
| enabler-decide | 1 | 9 | 9 | 7 |
| implementer | 9 | 383 | 2418 | 100 |
| implementer-salvage | 1 | 10 | 10 | 6 |
| refiner | 16 | 139 | 684 | 34 |
| reviewer | 9 | 1053 | 2489 | 251 |

## Per cycle (core/graphql spent while that cycle ran; window rolls excluded)

| cycle | node | readings | core spend | graphql spend |
|---|---|---:|---:|---:|
| 20260830T100300Z-poetic-2-1364 | poetic-2 | 5 | 1112 | 331 |
| 20260830T100900Z-ockham-2-5888 | ockham-2 | 7 | 1596 | 479 |
| 20260830T102529Z-poetic-2-87404 | poetic-2 | 6 | 1275 | 359 |
| 20260830T120855Z-ockham-2-5385 | ockham-2 | 5 | 2497 | 702 |
| 20260830T121200Z-poetic-1-5197 | poetic-1 | 5 | 1345 | 366 |
| 20260830T123057Z-poetic-1-37606 | poetic-1 | 4 | 1596 | 451 |
| 20260830T125700Z-poetic-1-116081 | poetic-1 | 4 | 734 | 256 |
| 20260830T130741Z-poetic-2-959225 | poetic-2 | 1 | 0 | 0 |
| 20260830T131020Z-poetic-1-137734 | poetic-1 | 3 | 906 | 257 |
| 20260830T131800Z-poetic-2-5712 | poetic-2 | 3 | 819 | 228 |
| 20260830T132700Z-poetic-1-163209 | poetic-1 | 4 | 1095 | 329 |
| 20260830T133300Z-poetic-2-89 | poetic-2 | 4 | 745 | 233 |
| 20260830T133718Z-ockham-2-31881 | ockham-2 | 3 | 669 | 193 |
| 20260830T134200Z-poetic-1-186709 | poetic-1 | 3 | 856 | 265 |
| 20260830T134800Z-poetic-2-23702 | poetic-2 | 6 | 3697 | 698 |
| 20260830T135400Z-ockham-2-1361 | ockham-2 | 3 | 633 | 202 |
| 20260830T135700Z-poetic-1-3549 | poetic-1 | 3 | 929 | 173 |
| 20260830T140600Z-ockham-container-2571 | ockham-container | 7 | 3423 | 852 |
| 20260830T140900Z-ockham-2-1369 | ockham-2 | 3 | 1045 | 166 |
| 20260830T141200Z-poetic-1-34954 | poetic-1 | 3 | 825 | 155 |
| 20260830T142400Z-ockham-2-23651 | ockham-2 | 4 | 485 | 179 |
| 20260830T142700Z-poetic-1-60515 | poetic-1 | 3 | 363 | 148 |
| 20260830T143300Z-poetic-2-3127 | poetic-2 | 6 | 720 | 226 |
| 20260830T143900Z-ockham-2-10112 | ockham-2 | 2 | 2 | 0 |
| 20260830T144200Z-poetic-1-79320 | poetic-1 | 2 | 1 | 0 |
| 20260830T145400Z-ockham-2-21573 | ockham-2 | 4 | 2205 | 322 |
| 20260830T145700Z-poetic-1-90993 | poetic-1 | 3 | 1991 | 274 |
| 20260830T145709Z-ockham-container-26443 | ockham-container | 3 | 1636 | 213 |
| 20260830T145806Z-poetic-2-36464 | poetic-2 | 3 | 1810 | 244 |
| 20260830T150600Z-ockham-container-19632 | ockham-container | 3 | 891 | 124 |
| 20260830T150900Z-ockham-2-11181 | ockham-2 | 3 | 1098 | 246 |
| 20260830T151200Z-poetic-1-111658 | poetic-1 | 3 | 617 | 127 |
| 20260830T151800Z-poetic-2-76235 | poetic-2 | 4 | 697 | 193 |
| 20260830T152100Z-ockham-container-10136 | ockham-container | 4 | 469 | 149 |
| 20260830T152400Z-ockham-2-29558 | ockham-2 | 2 | 4 | 0 |
| 20260830T152700Z-poetic-1-130159 | poetic-1 | 2 | 0 | 0 |
| 20260830T153300Z-poetic-2-97901 | poetic-2 | 2 | 0 | 0 |
| 20260830T153600Z-ockham-container-913 | ockham-container | 2 | 0 | 0 |
| 20260830T153900Z-ockham-2-9727 | ockham-2 | 2 | 0 | 2 |
| 20260830T154200Z-poetic-1-143225 | poetic-1 | 2 | 0 | 0 |
| 20260830T154800Z-poetic-2-109240 | poetic-2 | 2 | 0 | 0 |
| 20260830T155100Z-ockham-container-13602 | ockham-container | 3 | 3 | 0 |
| 20260830T155400Z-ockham-2-21422 | ockham-2 | 3 | 427 | 143 |
| 20260830T155700Z-poetic-1-155608 | poetic-1 | 3 | 320 | 128 |
| 20260830T160300Z-poetic-2-119565 | poetic-2 | 2 | 378 | 116 |
| 20260830T160600Z-ockham-container-29529 | ockham-container | 2 | 413 | 142 |
| 20260830T160900Z-ockham-2-7379 | ockham-2 | 3 | 588 | 155 |
| 20260830T161200Z-poetic-1-174025 | poetic-1 | 3 | 690 | 157 |
| 20260830T161800Z-poetic-2-137493 | poetic-2 | 7 | 3441 | 1191 |
| 20260830T162100Z-ockham-container-15382 | ockham-container | 3 | 821 | 173 |
| 20260830T162400Z-ockham-2-28910 | ockham-2 | 6 | 1620 | 495 |
| 20260830T162700Z-poetic-1-195801 | poetic-1 | 3 | 328 | 113 |
| 20260830T163600Z-ockham-container-5373 | ockham-container | 3 | 254 | 80 |
| 20260830T164200Z-poetic-1-213854 | poetic-1 | 2 | 320 | 102 |
| 20260830T165100Z-ockham-container-23716 | ockham-container | 3 | 3 | 1 |
| 20260830T165513Z-ockham-2-31379 | ockham-2 | 3 | 1338 | 309 |
| 20260830T165700Z-poetic-1-233236 | poetic-1 | 3 | 993 | 214 |
| 20260830T170600Z-ockham-container-6993 | ockham-container | 3 | 769 | 196 |
| 20260830T170900Z-ockham-2-14858 | ockham-2 | 3 | 746 | 199 |
| 20260830T171200Z-poetic-1-254545 | poetic-1 | 5 | 1406 | 581 |
| 20260830T171658Z-ockham-2-1157 | ockham-2 | 3 | 440 | 179 |
| 20260830T172100Z-ockham-container-29902 | ockham-container | 3 | 490 | 206 |
| 20260830T172400Z-ockham-2-14601 | ockham-2 | 3 | 327 | 163 |
| 20260830T173433Z-poetic-1-298310 | poetic-1 | 3 | 807 | 261 |
| 20260830T173600Z-ockham-container-14825 | ockham-container | 3 | 720 | 231 |
| 20260830T173900Z-ockham-2-32194 | ockham-2 | 3 | 576 | 210 |
| 20260830T175034Z-poetic-2-507494 | poetic-2 | 2 | 1 | 0 |
| 20260830T175100Z-ockham-container-2350 | ockham-container | 3 | 6 | 1 |
| 20260830T175400Z-ockham-2-22551 | ockham-2 | 3 | 633 | 212 |
| 20260830T175700Z-poetic-1-325006 | poetic-1 | 3 | 597 | 200 |
| 20260830T180300Z-poetic-2-516948 | poetic-2 | 3 | 657 | 261 |
| 20260830T180600Z-ockham-container-23962 | ockham-container | 2 | 438 | 169 |
| 20260830T180900Z-ockham-2-7762 | ockham-2 | 3 | 533 | 221 |
| 20260830T181200Z-poetic-1-346891 | poetic-1 | 3 | 414 | 177 |
| 20260830T181800Z-poetic-2-536012 | poetic-2 | 2 | 440 | 167 |
| 20260830T182100Z-ockham-container-9392 | ockham-container | 2 | 470 | 196 |
| 20260830T182400Z-ockham-2-25514 | ockham-2 | 3 | 686 | 236 |
| 20260830T182700Z-poetic-1-365982 | poetic-1 | 2 | 489 | 157 |
| 20260830T183300Z-poetic-2-554524 | poetic-2 | 3 | 883 | 250 |
| 20260830T183600Z-ockham-container-26256 | ockham-container | 3 | 1001 | 302 |
| 20260830T183900Z-ockham-2-13903 | ockham-2 | 2 | 626 | 207 |
| 20260830T184200Z-poetic-1-383679 | poetic-1 | 4 | 29 | 4 |
| 20260830T184245Z-poetic-2-573527 | poetic-2 | 3 | 518 | 236 |
| 20260830T185100Z-ockham-container-17392 | ockham-container | 3 | 2 | 0 |
| 20260830T185400Z-ockham-2-32610 | ockham-2 | 3 | 578 | 227 |
| 20260830T185817Z-poetic-1-409233 | poetic-1 | 6 | 1541 | 512 |
| 20260830T190300Z-poetic-2-597453 | poetic-2 | 3 | 558 | 234 |
| 20260830T190600Z-ockham-container-3918 | ockham-container | 3 | 546 | 236 |
| 20260830T190900Z-ockham-2-18123 | ockham-2 | 3 | 532 | 191 |
| 20260830T191800Z-poetic-2-616789 | poetic-2 | 4 | 1055 | 278 |
| 20260830T192100Z-ockham-container-22588 | ockham-container | 3 | 816 | 203 |
| 20260830T192400Z-ockham-2-8311 | ockham-2 | 3 | 505 | 151 |
| 20260830T193300Z-poetic-2-638900 | poetic-2 | 3 | 460 | 123 |
| 20260830T193600Z-ockham-container-10177 | ockham-container | 3 | 543 | 151 |
| 20260830T193900Z-ockham-2-25381 | ockham-2 | 3 | 398 | 116 |
| 20260830T194800Z-poetic-2-659962 | poetic-2 | 3 | 5 | 2 |
| 20260830T195100Z-ockham-container-31126 | ockham-container | 3 | 6 | 2 |
| 20260830T195400Z-ockham-2-13374 | ockham-2 | 3 | 496 | 146 |
| 20260830T200300Z-poetic-2-676489 | poetic-2 | 3 | 452 | 136 |
| 20260830T201800Z-poetic-2-697749 | poetic-2 | 3 | 246 | 76 |
| 20260830T203300Z-poetic-2-714595 | poetic-2 | 3 | 244 | 95 |
| 20260830T204105Z-poetic-1-890234 | poetic-1 | 6 | 489 | 174 |
| 20260830T204800Z-poetic-2-732627 | poetic-2 | 4 | 56 | 15 |
| 20260830T210300Z-poetic-2-752609 | poetic-2 | 4 | 307 | 116 |
| 20260830T211800Z-poetic-2-771406 | poetic-2 | 3 | 238 | 102 |
| 20260830T213300Z-poetic-2-789203 | poetic-2 | 4 | 378 | 111 |
| 20260830T214800Z-poetic-2-811680 | poetic-2 | 4 | 84 | 22 |
| 20260830T215659Z-poetic-2-827005 | poetic-2 | 3 | 256 | 96 |
| 20260830T221800Z-poetic-2-848500 | poetic-2 | 3 | 683 | 161 |
| 20260830T222802Z-poetic-2-867135 | poetic-2 | 3 | 417 | 137 |
| 20260830T224800Z-poetic-2-892863 | poetic-2 | 4 | 93 | 28 |
| 20260830T230300Z-poetic-2-910630 | poetic-2 | 6 | 869 | 278 |
| 20260831T002100Z-ockham-container-10517 | ockham-container | 4 | 875 | 181 |
| 20260831T002700Z-poetic-1-2404971 | poetic-1 | 3 | 776 | 154 |
| 20260831T003131Z-ockham-container-29801 | ockham-container | 3 | 463 | 110 |
| 20260831T004200Z-poetic-1-2426887 | poetic-1 | 3 | 444 | 114 |
| 20260831T005100Z-ockham-container-21865 | ockham-container | 4 | 192 | 99 |
| 20260831T005700Z-poetic-1-2446378 | poetic-1 | 3 | 343 | 128 |
| 20260831T010600Z-ockham-container-8006 | ockham-container | 4 | 664 | 178 |
| 20260831T011200Z-poetic-1-2463670 | poetic-1 | 3 | 571 | 146 |
| 20260831T012100Z-ockham-container-29745 | ockham-container | 3 | 533 | 205 |
| 20260831T012700Z-poetic-1-2484943 | poetic-1 | 3 | 455 | 147 |
| 20260831T013600Z-ockham-container-17851 | ockham-container | 4 | 633 | 211 |
| 20260831T014200Z-poetic-1-2503425 | poetic-1 | 3 | 520 | 156 |
| 20260831T014447Z-poetic-2-1772235 | poetic-2 | 3 | 430 | 152 |
| 20260831T015100Z-ockham-container-4710 | ockham-container | 6 | 1854 | 708 |
| 20260831T015700Z-poetic-1-2522165 | poetic-1 | 4 | 667 | 222 |
| 20260831T020300Z-poetic-2-1795782 | poetic-2 | 3 | 335 | 145 |
| 20260831T021200Z-poetic-1-2543036 | poetic-1 | 3 | 307 | 109 |
| 20260831T021800Z-poetic-2-1813313 | poetic-2 | 3 | 509 | 146 |
| 20260831T022700Z-poetic-1-2561725 | poetic-1 | 2 | 341 | 124 |
| 20260831T023300Z-poetic-2-1835381 | poetic-2 | 3 | 360 | 111 |
| 20260831T024200Z-poetic-1-2579885 | poetic-1 | 3 | 747 | 175 |
| 20260831T024800Z-poetic-2-1859446 | poetic-2 | 3 | 3 | 0 |
| 20260831T025700Z-poetic-1-2609975 | poetic-1 | 3 | 317 | 112 |
| 20260831T030300Z-poetic-2-1881647 | poetic-2 | 3 | 509 | 138 |
| 20260831T031200Z-poetic-1-2627684 | poetic-1 | 3 | 491 | 239 |
| 20260831T031217Z-poetic-2-1901236 | poetic-2 | 3 | 495 | 262 |
| 20260831T032700Z-poetic-1-2646039 | poetic-1 | 6 | 1165 | 386 |
| 20260831T033300Z-poetic-2-1925763 | poetic-2 | 3 | 614 | 237 |
| 20260831T033358Z-ockham-container-23496 | ockham-container | 3 | 485 | 181 |
| 20260831T034800Z-poetic-2-89 | poetic-2 | 4 | 95 | 22 |
| 20260831T035100Z-ockham-container-3033 | ockham-container | 3 | 7 | 0 |
| 20260831T040300Z-poetic-2-21445 | poetic-2 | 3 | 500 | 163 |
| 20260831T040600Z-ockham-container-24275 | ockham-container | 3 | 376 | 163 |
| 20260831T041800Z-poetic-2-40752 | poetic-2 | 5 | 633 | 309 |
| 20260831T042100Z-ockham-container-11155 | ockham-container | 3 | 370 | 193 |
| 20260831T043300Z-poetic-2-61193 | poetic-2 | 3 | 805 | 209 |
| 20260831T043600Z-ockham-container-30136 | ockham-container | 3 | 734 | 173 |
| 20260831T044200Z-poetic-1-2626 | poetic-1 | 3 | 717 | 203 |
| 20260831T044305Z-poetic-2-77832 | poetic-2 | 3 | 624 | 175 |
| 20260831T045100Z-ockham-container-21440 | ockham-container | 3 | 18 | 6 |
| 20260831T045700Z-poetic-1-24621 | poetic-1 | 3 | 456 | 136 |
| 20260831T045909Z-ockham-container-2796 | ockham-container | 3 | 501 | 170 |
| 20260831T050300Z-poetic-2-102485 | poetic-2 | 3 | 563 | 183 |
| 20260831T050600Z-ockham-container-17383 | ockham-container | 3 | 978 | 233 |
| 20260831T050900Z-ockham-2-24213 | ockham-2 | 3 | 938 | 224 |
| 20260831T051200Z-poetic-1-42396 | poetic-1 | 3 | 632 | 178 |
| 20260831T051620Z-ockham-container-3866 | ockham-container | 3 | 704 | 205 |
| 20260831T051800Z-poetic-2-121433 | poetic-2 | 3 | 804 | 221 |
| 20260831T051831Z-ockham-2-10643 | ockham-2 | 3 | 721 | 203 |
| 20260831T052700Z-poetic-1-60980 | poetic-1 | 3 | 511 | 118 |
| 20260831T053300Z-poetic-2-2985 | poetic-2 | 2 | 401 | 138 |
| 20260831T053600Z-ockham-container-3357 | ockham-container | 2 | 463 | 149 |
| 20260831T053900Z-ockham-2-6175 | ockham-2 | 3 | 467 | 149 |
| 20260831T054200Z-poetic-1-2454 | poetic-1 | 3 | 435 | 141 |
| 20260831T054800Z-poetic-2-21261 | poetic-2 | 3 | 2 | 0 |
| 20260831T054954Z-poetic-1-17002 | poetic-1 | 2 | 2 | 1 |
| 20260831T055100Z-ockham-container-22900 | ockham-container | 2 | 2 | 0 |
| 20260831T055400Z-ockham-2-23958 | ockham-2 | 3 | 5 | 2 |
| 20260831T055700Z-poetic-1-24587 | poetic-1 | 3 | 551 | 151 |
| 20260831T060300Z-poetic-2-39991 | poetic-2 | 3 | 874 | 195 |
| 20260831T060600Z-ockham-container-1217 | ockham-container | 3 | 866 | 207 |
| 20260831T060900Z-ockham-2-11970 | ockham-2 | 3 | 694 | 188 |
| 20260831T061200Z-poetic-1-42296 | poetic-1 | 4 | 769 | 194 |
| 20260831T061800Z-poetic-2-62179 | poetic-2 | 3 | 559 | 222 |
| 20260831T062100Z-ockham-container-23388 | ockham-container | 3 | 673 | 277 |
| 20260831T062400Z-ockham-2-31037 | ockham-2 | 3 | 528 | 176 |
| 20260831T062700Z-poetic-1-64354 | poetic-1 | 2 | 376 | 115 |
| 20260831T063300Z-poetic-2-81250 | poetic-2 | 2 | 397 | 108 |
| 20260831T063600Z-ockham-container-8667 | ockham-container | 3 | 462 | 139 |
| 20260831T063900Z-ockham-2-89 | ockham-2 | 3 | 607 | 148 |
| 20260831T064200Z-poetic-1-2615 | poetic-1 | 3 | 489 | 127 |
| 20260831T064800Z-poetic-2-3618 | poetic-2 | 3 | 10 | 2 |
| 20260831T065100Z-ockham-container-6157 | ockham-container | 2 | 1 | 0 |
| 20260831T065400Z-ockham-2-23025 | ockham-2 | 3 | 4 | 0 |
| 20260831T065700Z-poetic-1-22165 | poetic-1 | 2 | 524 | 122 |
| 20260831T070300Z-poetic-2-23793 | poetic-2 | 2 | 413 | 131 |
| 20260831T070600Z-ockham-container-16919 | ockham-container | 2 | 579 | 139 |
| 20260831T070900Z-ockham-2-7700 | ockham-2 | 2 | 509 | 121 |
| 20260831T071200Z-poetic-1-42076 | poetic-1 | 2 | 341 | 104 |
| 20260831T071800Z-poetic-2-42710 | poetic-2 | 2 | 395 | 101 |
| 20260831T072100Z-ockham-container-7816 | ockham-container | 2 | 400 | 126 |
| 20260831T072400Z-ockham-2-26667 | ockham-2 | 2 | 570 | 134 |
| 20260831T072700Z-poetic-1-61090 | poetic-1 | 2 | 418 | 101 |
| 20260831T073300Z-poetic-2-61005 | poetic-2 | 4 | 1182 | 283 |
| 20260831T073600Z-ockham-container-24957 | ockham-container | 3 | 640 | 146 |
| 20260831T073900Z-ockham-2-13723 | ockham-2 | 3 | 526 | 171 |
| 20260831T074200Z-poetic-1-78938 | poetic-1 | 3 | 799 | 199 |
| 20260831T074616Z-ockham-2-28940 | ockham-2 | 3 | 10 | 2 |
| 20260831T074800Z-poetic-2-85018 | poetic-2 | 3 | 47 | 6 |
| 20260831T075055Z-poetic-1-97470 | poetic-1 | 2 | 0 | 0 |
| 20260831T075100Z-ockham-container-11722 | ockham-container | 3 | 13 | 3 |
| 20260831T075400Z-ockham-2-10698 | ockham-2 | 3 | 4 | 0 |
| 20260831T075541Z-poetic-2-101257 | poetic-2 | 3 | 714 | 190 |
| 20260831T075700Z-poetic-1-103742 | poetic-1 | 3 | 584 | 159 |
| 20260831T080300Z-poetic-2-115133 | poetic-2 | 2 | 650 | 166 |
| 20260831T080600Z-ockham-container-2151 | ockham-container | 2 | 527 | 122 |
| 20260831T080900Z-ockham-2-31565 | ockham-2 | 2 | 386 | 141 |
| 20260831T081200Z-poetic-1-122764 | poetic-1 | 2 | 321 | 109 |
| 20260831T081800Z-poetic-2-135509 | poetic-2 | 2 | 374 | 104 |
| 20260831T082100Z-ockham-container-19560 | ockham-container | 2 | 412 | 131 |
| 20260831T082400Z-ockham-2-16972 | ockham-2 | 2 | 378 | 116 |
| 20260831T082700Z-poetic-1-141296 | poetic-1 | 2 | 494 | 117 |
| 20260831T083300Z-poetic-2-154035 | poetic-2 | 2 | 420 | 150 |
| 20260831T083600Z-ockham-container-5993 | ockham-container | 2 | 612 | 188 |
| 20260831T083900Z-ockham-2-2895 | ockham-2 | 2 | 667 | 145 |
| 20260831T084200Z-poetic-1-163188 | poetic-1 | 2 | 427 | 115 |
| 20260831T084800Z-poetic-2-172711 | poetic-2 | 2 | 2 | 0 |
| 20260831T085100Z-ockham-container-28986 | ockham-container | 3 | 33 | 4 |
| 20260831T085400Z-ockham-2-24050 | ockham-2 | 3 | 9 | 2 |
| 20260831T085700Z-poetic-1-181638 | poetic-1 | 3 | 559 | 185 |
| 20260831T085820Z-ockham-container-9773 | ockham-container | 3 | 424 | 135 |
| 20260831T090300Z-poetic-2-180725 | poetic-2 | 3 | 1185 | 260 |
| 20260831T090503Z-ockham-container-21754 | ockham-container | 3 | 1113 | 247 |
| 20260831T090507Z-poetic-1-194419 | poetic-1 | 3 | 1180 | 283 |
| 20260831T090900Z-ockham-2-7728 | ockham-2 | 3 | 551 | 169 |
| 20260831T091430Z-poetic-1-214172 | poetic-1 | 3 | 511 | 134 |
| 20260831T091800Z-poetic-2-202617 | poetic-2 | 3 | 604 | 189 |
| 20260831T092100Z-ockham-container-14219 | ockham-container | 3 | 498 | 165 |
| 20260831T092400Z-ockham-2-24354 | ockham-2 | 3 | 500 | 140 |
| 20260831T093300Z-poetic-2-222021 | poetic-2 | 3 | 416 | 170 |
| 20260831T093600Z-ockham-container-446 | ockham-container | 6 | 689 | 321 |
| 20260831T093900Z-ockham-2-13657 | ockham-2 | 3 | 342 | 123 |
| 20260831T094800Z-poetic-2-241214 | poetic-2 | 3 | 10 | 1 |
| 20260831T095400Z-ockham-2-360 | ockham-2 | 6 | 2367 | 889 |
| 20260831T100300Z-poetic-2-261583 | poetic-2 | 3 | 341 | 178 |
| 20260831T101800Z-poetic-2-280294 | poetic-2 | 6 | 2580 | 961 |
| 20260831T102632Z-ockham-container-30016 | ockham-container | 3 | 559 | 177 |
| 20260831T110600Z-ockham-container-17549 | ockham-container | 4 | 328 | 189 |
| 20260831T112100Z-ockham-container-6221 | ockham-container | 3 | 871 | 258 |
| 20260831T112955Z-ockham-container-20200 | ockham-container | 3 | 632 | 245 |
| 20260831T113843Z-ockham-container-8543 | ockham-container | 3 | 347 | 157 |
| 20260831T115100Z-ockham-container-27933 | ockham-container | 2 | 0 | 0 |
| 20260831T115400Z-ockham-2-1083 | ockham-2 | 1 | 0 | 0 |

## Per node

| node | readings | unreadable | cycles with a record |
|---|---:|---:|---:|
| ockham-2 | 153 | 0 | 50 |
| ockham-container | 189 | 0 | 62 |
| poetic-1 | 190 | 0 | 62 |
| poetic-2 | 231 | 1 | 71 |

## `gh` transport shim (requirement 2.0e)

No `gh-shim/ledger.ndjson` entries in the logs read — nothing to report. The ledger is
written by `lib/gh-shim.sh` from the first cycle that runs an image carrying it.

```json
{
  "readings": 763,
  "readable": 762,
  "first_ts": "2026-08-30T10:03:05Z",
  "last_ts": "2026-08-31T11:58:01Z",
  "per_hour": [
    {
      "hour": "2026-08-29T14",
      "readings": 0,
      "core_peak_used": null,
      "core_min_remaining": null,
      "graphql_peak_used": null,
      "refusals": 12,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-29T15",
      "readings": 0,
      "core_peak_used": null,
      "core_min_remaining": null,
      "graphql_peak_used": null,
      "refusals": 1,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-29T16",
      "readings": 0,
      "core_peak_used": null,
      "core_min_remaining": null,
      "graphql_peak_used": null,
      "refusals": 25,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-29T20",
      "readings": 0,
      "core_peak_used": null,
      "core_min_remaining": null,
      "graphql_peak_used": null,
      "refusals": 5,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T04",
      "readings": 0,
      "core_peak_used": null,
      "core_min_remaining": null,
      "graphql_peak_used": null,
      "refusals": 6,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T06",
      "readings": 0,
      "core_peak_used": null,
      "core_min_remaining": null,
      "graphql_peak_used": null,
      "refusals": 6,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T07",
      "readings": 0,
      "core_peak_used": null,
      "core_min_remaining": null,
      "graphql_peak_used": null,
      "refusals": 6,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T10",
      "readings": 11,
      "core_peak_used": 2644,
      "core_min_remaining": 2356,
      "graphql_peak_used": 815,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T11",
      "readings": 2,
      "core_peak_used": 79,
      "core_min_remaining": 4921,
      "graphql_peak_used": 49,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T12",
      "readings": 15,
      "core_peak_used": 4230,
      "core_min_remaining": 770,
      "graphql_peak_used": 1249,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T13",
      "readings": 33,
      "core_peak_used": 4786,
      "core_min_remaining": 214,
      "graphql_peak_used": 1433,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T14",
      "readings": 42,
      "core_peak_used": 5000,
      "core_min_remaining": 0,
      "graphql_peak_used": 1190,
      "refusals": 0,
      "budget_standdowns": 2
    },
    {
      "hour": "2026-08-30T15",
      "readings": 47,
      "core_peak_used": 5000,
      "core_min_remaining": 0,
      "graphql_peak_used": 991,
      "refusals": 0,
      "budget_standdowns": 7
    },
    {
      "hour": "2026-08-30T16",
      "readings": 36,
      "core_peak_used": 4166,
      "core_min_remaining": 834,
      "graphql_peak_used": 1181,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T17",
      "readings": 47,
      "core_peak_used": 4803,
      "core_min_remaining": 197,
      "graphql_peak_used": 1539,
      "refusals": 0,
      "budget_standdowns": 1
    },
    {
      "hour": "2026-08-30T18",
      "readings": 42,
      "core_peak_used": 5000,
      "core_min_remaining": 0,
      "graphql_peak_used": 1803,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T19",
      "readings": 38,
      "core_peak_used": 4065,
      "core_min_remaining": 935,
      "graphql_peak_used": 1327,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T20",
      "readings": 21,
      "core_peak_used": 2353,
      "core_min_remaining": 2647,
      "graphql_peak_used": 700,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T21",
      "readings": 16,
      "core_peak_used": 1425,
      "core_min_remaining": 3575,
      "graphql_peak_used": 460,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T22",
      "readings": 13,
      "core_peak_used": 2334,
      "core_min_remaining": 2666,
      "graphql_peak_used": 698,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-30T23",
      "readings": 2,
      "core_peak_used": 879,
      "core_min_remaining": 4121,
      "graphql_peak_used": 179,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T00",
      "readings": 20,
      "core_peak_used": 3577,
      "core_min_remaining": 1423,
      "graphql_peak_used": 892,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T01",
      "readings": 33,
      "core_peak_used": 3653,
      "core_min_remaining": 1347,
      "graphql_peak_used": 1128,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T02",
      "readings": 25,
      "core_peak_used": 3612,
      "core_min_remaining": 1388,
      "graphql_peak_used": 1016,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T03",
      "readings": 29,
      "core_peak_used": 3487,
      "core_min_remaining": 1513,
      "graphql_peak_used": 1197,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T04",
      "readings": 35,
      "core_peak_used": 4264,
      "core_min_remaining": 736,
      "graphql_peak_used": 1231,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T05",
      "readings": 47,
      "core_peak_used": 4816,
      "core_min_remaining": 184,
      "graphql_peak_used": 1363,
      "refusals": 0,
      "budget_standdowns": 2
    },
    {
      "hour": "2026-08-31T06",
      "readings": 48,
      "core_peak_used": 4705,
      "core_min_remaining": 295,
      "graphql_peak_used": 1297,
      "refusals": 0,
      "budget_standdowns": 1
    },
    {
      "hour": "2026-08-31T07",
      "readings": 44,
      "core_peak_used": 5000,
      "core_min_remaining": 0,
      "graphql_peak_used": 1295,
      "refusals": 0,
      "budget_standdowns": 1
    },
    {
      "hour": "2026-08-31T08",
      "readings": 40,
      "core_peak_used": 4970,
      "core_min_remaining": 30,
      "graphql_peak_used": 1265,
      "refusals": 0,
      "budget_standdowns": 1
    },
    {
      "hour": "2026-08-31T09",
      "readings": 40,
      "core_peak_used": 4421,
      "core_min_remaining": 579,
      "graphql_peak_used": 1457,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T10",
      "readings": 12,
      "core_peak_used": 2127,
      "core_min_remaining": 2873,
      "graphql_peak_used": 826,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-08-31T11",
      "readings": 25,
      "core_peak_used": 3147,
      "core_min_remaining": 1853,
      "graphql_peak_used": 1283,
      "refusals": 0,
      "budget_standdowns": 0
    }
  ],
  "per_stage": [
    {
      "stage": "approver",
      "readings": 17,
      "core_movement_median": 197,
      "core_movement_max": 919,
      "graphql_movement_median": 87
    },
    {
      "stage": "coordinator",
      "readings": 164,
      "core_movement_median": 551,
      "core_movement_max": 1952,
      "graphql_movement_median": 173
    },
    {
      "stage": "coordinator-salvage",
      "readings": 1,
      "core_movement_median": 32,
      "core_movement_max": 32,
      "graphql_movement_median": 2
    },
    {
      "stage": "enabler",
      "readings": 8,
      "core_movement_median": 178,
      "core_movement_max": 425,
      "graphql_movement_median": 82
    },
    {
      "stage": "enabler-decide",
      "readings": 1,
      "core_movement_median": 9,
      "core_movement_max": 9,
      "graphql_movement_median": 7
    },
    {
      "stage": "implementer",
      "readings": 9,
      "core_movement_median": 383,
      "core_movement_max": 2418,
      "graphql_movement_median": 100
    },
    {
      "stage": "implementer-salvage",
      "readings": 1,
      "core_movement_median": 10,
      "core_movement_max": 10,
      "graphql_movement_median": 6
    },
    {
      "stage": "refiner",
      "readings": 16,
      "core_movement_median": 139,
      "core_movement_max": 684,
      "graphql_movement_median": 34
    },
    {
      "stage": "reviewer",
      "readings": 9,
      "core_movement_median": 1053,
      "core_movement_max": 2489,
      "graphql_movement_median": 251
    }
  ],
  "per_cycle": [
    {
      "cycle": "20260830T100300Z-poetic-2-1364",
      "node": "poetic-2",
      "readings": 5,
      "core_spend": 1112,
      "graphql_spend": 331
    },
    {
      "cycle": "20260830T100900Z-ockham-2-5888",
      "node": "ockham-2",
      "readings": 7,
      "core_spend": 1596,
      "graphql_spend": 479
    },
    {
      "cycle": "20260830T102529Z-poetic-2-87404",
      "node": "poetic-2",
      "readings": 6,
      "core_spend": 1275,
      "graphql_spend": 359
    },
    {
      "cycle": "20260830T120855Z-ockham-2-5385",
      "node": "ockham-2",
      "readings": 5,
      "core_spend": 2497,
      "graphql_spend": 702
    },
    {
      "cycle": "20260830T121200Z-poetic-1-5197",
      "node": "poetic-1",
      "readings": 5,
      "core_spend": 1345,
      "graphql_spend": 366
    },
    {
      "cycle": "20260830T123057Z-poetic-1-37606",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 1596,
      "graphql_spend": 451
    },
    {
      "cycle": "20260830T125700Z-poetic-1-116081",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 734,
      "graphql_spend": 256
    },
    {
      "cycle": "20260830T130741Z-poetic-2-959225",
      "node": "poetic-2",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T131020Z-poetic-1-137734",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 906,
      "graphql_spend": 257
    },
    {
      "cycle": "20260830T131800Z-poetic-2-5712",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 819,
      "graphql_spend": 228
    },
    {
      "cycle": "20260830T132700Z-poetic-1-163209",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 1095,
      "graphql_spend": 329
    },
    {
      "cycle": "20260830T133300Z-poetic-2-89",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 745,
      "graphql_spend": 233
    },
    {
      "cycle": "20260830T133718Z-ockham-2-31881",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 669,
      "graphql_spend": 193
    },
    {
      "cycle": "20260830T134200Z-poetic-1-186709",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 856,
      "graphql_spend": 265
    },
    {
      "cycle": "20260830T134800Z-poetic-2-23702",
      "node": "poetic-2",
      "readings": 6,
      "core_spend": 3697,
      "graphql_spend": 698
    },
    {
      "cycle": "20260830T135400Z-ockham-2-1361",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 633,
      "graphql_spend": 202
    },
    {
      "cycle": "20260830T135700Z-poetic-1-3549",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 929,
      "graphql_spend": 173
    },
    {
      "cycle": "20260830T140600Z-ockham-container-2571",
      "node": "ockham-container",
      "readings": 7,
      "core_spend": 3423,
      "graphql_spend": 852
    },
    {
      "cycle": "20260830T140900Z-ockham-2-1369",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 1045,
      "graphql_spend": 166
    },
    {
      "cycle": "20260830T141200Z-poetic-1-34954",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 825,
      "graphql_spend": 155
    },
    {
      "cycle": "20260830T142400Z-ockham-2-23651",
      "node": "ockham-2",
      "readings": 4,
      "core_spend": 485,
      "graphql_spend": 179
    },
    {
      "cycle": "20260830T142700Z-poetic-1-60515",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 363,
      "graphql_spend": 148
    },
    {
      "cycle": "20260830T143300Z-poetic-2-3127",
      "node": "poetic-2",
      "readings": 6,
      "core_spend": 720,
      "graphql_spend": 226
    },
    {
      "cycle": "20260830T143900Z-ockham-2-10112",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 2,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T144200Z-poetic-1-79320",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 1,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T145400Z-ockham-2-21573",
      "node": "ockham-2",
      "readings": 4,
      "core_spend": 2205,
      "graphql_spend": 322
    },
    {
      "cycle": "20260830T145700Z-poetic-1-90993",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 1991,
      "graphql_spend": 274
    },
    {
      "cycle": "20260830T145709Z-ockham-container-26443",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 1636,
      "graphql_spend": 213
    },
    {
      "cycle": "20260830T145806Z-poetic-2-36464",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 1810,
      "graphql_spend": 244
    },
    {
      "cycle": "20260830T150600Z-ockham-container-19632",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 891,
      "graphql_spend": 124
    },
    {
      "cycle": "20260830T150900Z-ockham-2-11181",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 1098,
      "graphql_spend": 246
    },
    {
      "cycle": "20260830T151200Z-poetic-1-111658",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 617,
      "graphql_spend": 127
    },
    {
      "cycle": "20260830T151800Z-poetic-2-76235",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 697,
      "graphql_spend": 193
    },
    {
      "cycle": "20260830T152100Z-ockham-container-10136",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 469,
      "graphql_spend": 149
    },
    {
      "cycle": "20260830T152400Z-ockham-2-29558",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 4,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T152700Z-poetic-1-130159",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T153300Z-poetic-2-97901",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T153600Z-ockham-container-913",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T153900Z-ockham-2-9727",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 2
    },
    {
      "cycle": "20260830T154200Z-poetic-1-143225",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T154800Z-poetic-2-109240",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T155100Z-ockham-container-13602",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 3,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T155400Z-ockham-2-21422",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 427,
      "graphql_spend": 143
    },
    {
      "cycle": "20260830T155700Z-poetic-1-155608",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 320,
      "graphql_spend": 128
    },
    {
      "cycle": "20260830T160300Z-poetic-2-119565",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 378,
      "graphql_spend": 116
    },
    {
      "cycle": "20260830T160600Z-ockham-container-29529",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 413,
      "graphql_spend": 142
    },
    {
      "cycle": "20260830T160900Z-ockham-2-7379",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 588,
      "graphql_spend": 155
    },
    {
      "cycle": "20260830T161200Z-poetic-1-174025",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 690,
      "graphql_spend": 157
    },
    {
      "cycle": "20260830T161800Z-poetic-2-137493",
      "node": "poetic-2",
      "readings": 7,
      "core_spend": 3441,
      "graphql_spend": 1191
    },
    {
      "cycle": "20260830T162100Z-ockham-container-15382",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 821,
      "graphql_spend": 173
    },
    {
      "cycle": "20260830T162400Z-ockham-2-28910",
      "node": "ockham-2",
      "readings": 6,
      "core_spend": 1620,
      "graphql_spend": 495
    },
    {
      "cycle": "20260830T162700Z-poetic-1-195801",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 328,
      "graphql_spend": 113
    },
    {
      "cycle": "20260830T163600Z-ockham-container-5373",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 254,
      "graphql_spend": 80
    },
    {
      "cycle": "20260830T164200Z-poetic-1-213854",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 320,
      "graphql_spend": 102
    },
    {
      "cycle": "20260830T165100Z-ockham-container-23716",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 3,
      "graphql_spend": 1
    },
    {
      "cycle": "20260830T165513Z-ockham-2-31379",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 1338,
      "graphql_spend": 309
    },
    {
      "cycle": "20260830T165700Z-poetic-1-233236",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 993,
      "graphql_spend": 214
    },
    {
      "cycle": "20260830T170600Z-ockham-container-6993",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 769,
      "graphql_spend": 196
    },
    {
      "cycle": "20260830T170900Z-ockham-2-14858",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 746,
      "graphql_spend": 199
    },
    {
      "cycle": "20260830T171200Z-poetic-1-254545",
      "node": "poetic-1",
      "readings": 5,
      "core_spend": 1406,
      "graphql_spend": 581
    },
    {
      "cycle": "20260830T171658Z-ockham-2-1157",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 440,
      "graphql_spend": 179
    },
    {
      "cycle": "20260830T172100Z-ockham-container-29902",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 490,
      "graphql_spend": 206
    },
    {
      "cycle": "20260830T172400Z-ockham-2-14601",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 327,
      "graphql_spend": 163
    },
    {
      "cycle": "20260830T173433Z-poetic-1-298310",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 807,
      "graphql_spend": 261
    },
    {
      "cycle": "20260830T173600Z-ockham-container-14825",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 720,
      "graphql_spend": 231
    },
    {
      "cycle": "20260830T173900Z-ockham-2-32194",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 576,
      "graphql_spend": 210
    },
    {
      "cycle": "20260830T175034Z-poetic-2-507494",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 1,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T175100Z-ockham-container-2350",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 6,
      "graphql_spend": 1
    },
    {
      "cycle": "20260830T175400Z-ockham-2-22551",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 633,
      "graphql_spend": 212
    },
    {
      "cycle": "20260830T175700Z-poetic-1-325006",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 597,
      "graphql_spend": 200
    },
    {
      "cycle": "20260830T180300Z-poetic-2-516948",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 657,
      "graphql_spend": 261
    },
    {
      "cycle": "20260830T180600Z-ockham-container-23962",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 438,
      "graphql_spend": 169
    },
    {
      "cycle": "20260830T180900Z-ockham-2-7762",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 533,
      "graphql_spend": 221
    },
    {
      "cycle": "20260830T181200Z-poetic-1-346891",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 414,
      "graphql_spend": 177
    },
    {
      "cycle": "20260830T181800Z-poetic-2-536012",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 440,
      "graphql_spend": 167
    },
    {
      "cycle": "20260830T182100Z-ockham-container-9392",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 470,
      "graphql_spend": 196
    },
    {
      "cycle": "20260830T182400Z-ockham-2-25514",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 686,
      "graphql_spend": 236
    },
    {
      "cycle": "20260830T182700Z-poetic-1-365982",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 489,
      "graphql_spend": 157
    },
    {
      "cycle": "20260830T183300Z-poetic-2-554524",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 883,
      "graphql_spend": 250
    },
    {
      "cycle": "20260830T183600Z-ockham-container-26256",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 1001,
      "graphql_spend": 302
    },
    {
      "cycle": "20260830T183900Z-ockham-2-13903",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 626,
      "graphql_spend": 207
    },
    {
      "cycle": "20260830T184200Z-poetic-1-383679",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 29,
      "graphql_spend": 4
    },
    {
      "cycle": "20260830T184245Z-poetic-2-573527",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 518,
      "graphql_spend": 236
    },
    {
      "cycle": "20260830T185100Z-ockham-container-17392",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 2,
      "graphql_spend": 0
    },
    {
      "cycle": "20260830T185400Z-ockham-2-32610",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 578,
      "graphql_spend": 227
    },
    {
      "cycle": "20260830T185817Z-poetic-1-409233",
      "node": "poetic-1",
      "readings": 6,
      "core_spend": 1541,
      "graphql_spend": 512
    },
    {
      "cycle": "20260830T190300Z-poetic-2-597453",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 558,
      "graphql_spend": 234
    },
    {
      "cycle": "20260830T190600Z-ockham-container-3918",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 546,
      "graphql_spend": 236
    },
    {
      "cycle": "20260830T190900Z-ockham-2-18123",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 532,
      "graphql_spend": 191
    },
    {
      "cycle": "20260830T191800Z-poetic-2-616789",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 1055,
      "graphql_spend": 278
    },
    {
      "cycle": "20260830T192100Z-ockham-container-22588",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 816,
      "graphql_spend": 203
    },
    {
      "cycle": "20260830T192400Z-ockham-2-8311",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 505,
      "graphql_spend": 151
    },
    {
      "cycle": "20260830T193300Z-poetic-2-638900",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 460,
      "graphql_spend": 123
    },
    {
      "cycle": "20260830T193600Z-ockham-container-10177",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 543,
      "graphql_spend": 151
    },
    {
      "cycle": "20260830T193900Z-ockham-2-25381",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 398,
      "graphql_spend": 116
    },
    {
      "cycle": "20260830T194800Z-poetic-2-659962",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 5,
      "graphql_spend": 2
    },
    {
      "cycle": "20260830T195100Z-ockham-container-31126",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 6,
      "graphql_spend": 2
    },
    {
      "cycle": "20260830T195400Z-ockham-2-13374",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 496,
      "graphql_spend": 146
    },
    {
      "cycle": "20260830T200300Z-poetic-2-676489",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 452,
      "graphql_spend": 136
    },
    {
      "cycle": "20260830T201800Z-poetic-2-697749",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 246,
      "graphql_spend": 76
    },
    {
      "cycle": "20260830T203300Z-poetic-2-714595",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 244,
      "graphql_spend": 95
    },
    {
      "cycle": "20260830T204105Z-poetic-1-890234",
      "node": "poetic-1",
      "readings": 6,
      "core_spend": 489,
      "graphql_spend": 174
    },
    {
      "cycle": "20260830T204800Z-poetic-2-732627",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 56,
      "graphql_spend": 15
    },
    {
      "cycle": "20260830T210300Z-poetic-2-752609",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 307,
      "graphql_spend": 116
    },
    {
      "cycle": "20260830T211800Z-poetic-2-771406",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 238,
      "graphql_spend": 102
    },
    {
      "cycle": "20260830T213300Z-poetic-2-789203",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 378,
      "graphql_spend": 111
    },
    {
      "cycle": "20260830T214800Z-poetic-2-811680",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 84,
      "graphql_spend": 22
    },
    {
      "cycle": "20260830T215659Z-poetic-2-827005",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 256,
      "graphql_spend": 96
    },
    {
      "cycle": "20260830T221800Z-poetic-2-848500",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 683,
      "graphql_spend": 161
    },
    {
      "cycle": "20260830T222802Z-poetic-2-867135",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 417,
      "graphql_spend": 137
    },
    {
      "cycle": "20260830T224800Z-poetic-2-892863",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 93,
      "graphql_spend": 28
    },
    {
      "cycle": "20260830T230300Z-poetic-2-910630",
      "node": "poetic-2",
      "readings": 6,
      "core_spend": 869,
      "graphql_spend": 278
    },
    {
      "cycle": "20260831T002100Z-ockham-container-10517",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 875,
      "graphql_spend": 181
    },
    {
      "cycle": "20260831T002700Z-poetic-1-2404971",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 776,
      "graphql_spend": 154
    },
    {
      "cycle": "20260831T003131Z-ockham-container-29801",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 463,
      "graphql_spend": 110
    },
    {
      "cycle": "20260831T004200Z-poetic-1-2426887",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 444,
      "graphql_spend": 114
    },
    {
      "cycle": "20260831T005100Z-ockham-container-21865",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 192,
      "graphql_spend": 99
    },
    {
      "cycle": "20260831T005700Z-poetic-1-2446378",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 343,
      "graphql_spend": 128
    },
    {
      "cycle": "20260831T010600Z-ockham-container-8006",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 664,
      "graphql_spend": 178
    },
    {
      "cycle": "20260831T011200Z-poetic-1-2463670",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 571,
      "graphql_spend": 146
    },
    {
      "cycle": "20260831T012100Z-ockham-container-29745",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 533,
      "graphql_spend": 205
    },
    {
      "cycle": "20260831T012700Z-poetic-1-2484943",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 455,
      "graphql_spend": 147
    },
    {
      "cycle": "20260831T013600Z-ockham-container-17851",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 633,
      "graphql_spend": 211
    },
    {
      "cycle": "20260831T014200Z-poetic-1-2503425",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 520,
      "graphql_spend": 156
    },
    {
      "cycle": "20260831T014447Z-poetic-2-1772235",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 430,
      "graphql_spend": 152
    },
    {
      "cycle": "20260831T015100Z-ockham-container-4710",
      "node": "ockham-container",
      "readings": 6,
      "core_spend": 1854,
      "graphql_spend": 708
    },
    {
      "cycle": "20260831T015700Z-poetic-1-2522165",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 667,
      "graphql_spend": 222
    },
    {
      "cycle": "20260831T020300Z-poetic-2-1795782",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 335,
      "graphql_spend": 145
    },
    {
      "cycle": "20260831T021200Z-poetic-1-2543036",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 307,
      "graphql_spend": 109
    },
    {
      "cycle": "20260831T021800Z-poetic-2-1813313",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 509,
      "graphql_spend": 146
    },
    {
      "cycle": "20260831T022700Z-poetic-1-2561725",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 341,
      "graphql_spend": 124
    },
    {
      "cycle": "20260831T023300Z-poetic-2-1835381",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 360,
      "graphql_spend": 111
    },
    {
      "cycle": "20260831T024200Z-poetic-1-2579885",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 747,
      "graphql_spend": 175
    },
    {
      "cycle": "20260831T024800Z-poetic-2-1859446",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 3,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T025700Z-poetic-1-2609975",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 317,
      "graphql_spend": 112
    },
    {
      "cycle": "20260831T030300Z-poetic-2-1881647",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 509,
      "graphql_spend": 138
    },
    {
      "cycle": "20260831T031200Z-poetic-1-2627684",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 491,
      "graphql_spend": 239
    },
    {
      "cycle": "20260831T031217Z-poetic-2-1901236",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 495,
      "graphql_spend": 262
    },
    {
      "cycle": "20260831T032700Z-poetic-1-2646039",
      "node": "poetic-1",
      "readings": 6,
      "core_spend": 1165,
      "graphql_spend": 386
    },
    {
      "cycle": "20260831T033300Z-poetic-2-1925763",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 614,
      "graphql_spend": 237
    },
    {
      "cycle": "20260831T033358Z-ockham-container-23496",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 485,
      "graphql_spend": 181
    },
    {
      "cycle": "20260831T034800Z-poetic-2-89",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 95,
      "graphql_spend": 22
    },
    {
      "cycle": "20260831T035100Z-ockham-container-3033",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 7,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T040300Z-poetic-2-21445",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 500,
      "graphql_spend": 163
    },
    {
      "cycle": "20260831T040600Z-ockham-container-24275",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 376,
      "graphql_spend": 163
    },
    {
      "cycle": "20260831T041800Z-poetic-2-40752",
      "node": "poetic-2",
      "readings": 5,
      "core_spend": 633,
      "graphql_spend": 309
    },
    {
      "cycle": "20260831T042100Z-ockham-container-11155",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 370,
      "graphql_spend": 193
    },
    {
      "cycle": "20260831T043300Z-poetic-2-61193",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 805,
      "graphql_spend": 209
    },
    {
      "cycle": "20260831T043600Z-ockham-container-30136",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 734,
      "graphql_spend": 173
    },
    {
      "cycle": "20260831T044200Z-poetic-1-2626",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 717,
      "graphql_spend": 203
    },
    {
      "cycle": "20260831T044305Z-poetic-2-77832",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 624,
      "graphql_spend": 175
    },
    {
      "cycle": "20260831T045100Z-ockham-container-21440",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 18,
      "graphql_spend": 6
    },
    {
      "cycle": "20260831T045700Z-poetic-1-24621",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 456,
      "graphql_spend": 136
    },
    {
      "cycle": "20260831T045909Z-ockham-container-2796",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 501,
      "graphql_spend": 170
    },
    {
      "cycle": "20260831T050300Z-poetic-2-102485",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 563,
      "graphql_spend": 183
    },
    {
      "cycle": "20260831T050600Z-ockham-container-17383",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 978,
      "graphql_spend": 233
    },
    {
      "cycle": "20260831T050900Z-ockham-2-24213",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 938,
      "graphql_spend": 224
    },
    {
      "cycle": "20260831T051200Z-poetic-1-42396",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 632,
      "graphql_spend": 178
    },
    {
      "cycle": "20260831T051620Z-ockham-container-3866",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 704,
      "graphql_spend": 205
    },
    {
      "cycle": "20260831T051800Z-poetic-2-121433",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 804,
      "graphql_spend": 221
    },
    {
      "cycle": "20260831T051831Z-ockham-2-10643",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 721,
      "graphql_spend": 203
    },
    {
      "cycle": "20260831T052700Z-poetic-1-60980",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 511,
      "graphql_spend": 118
    },
    {
      "cycle": "20260831T053300Z-poetic-2-2985",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 401,
      "graphql_spend": 138
    },
    {
      "cycle": "20260831T053600Z-ockham-container-3357",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 463,
      "graphql_spend": 149
    },
    {
      "cycle": "20260831T053900Z-ockham-2-6175",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 467,
      "graphql_spend": 149
    },
    {
      "cycle": "20260831T054200Z-poetic-1-2454",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 435,
      "graphql_spend": 141
    },
    {
      "cycle": "20260831T054800Z-poetic-2-21261",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 2,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T054954Z-poetic-1-17002",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 2,
      "graphql_spend": 1
    },
    {
      "cycle": "20260831T055100Z-ockham-container-22900",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 2,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T055400Z-ockham-2-23958",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 5,
      "graphql_spend": 2
    },
    {
      "cycle": "20260831T055700Z-poetic-1-24587",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 551,
      "graphql_spend": 151
    },
    {
      "cycle": "20260831T060300Z-poetic-2-39991",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 874,
      "graphql_spend": 195
    },
    {
      "cycle": "20260831T060600Z-ockham-container-1217",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 866,
      "graphql_spend": 207
    },
    {
      "cycle": "20260831T060900Z-ockham-2-11970",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 694,
      "graphql_spend": 188
    },
    {
      "cycle": "20260831T061200Z-poetic-1-42296",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 769,
      "graphql_spend": 194
    },
    {
      "cycle": "20260831T061800Z-poetic-2-62179",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 559,
      "graphql_spend": 222
    },
    {
      "cycle": "20260831T062100Z-ockham-container-23388",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 673,
      "graphql_spend": 277
    },
    {
      "cycle": "20260831T062400Z-ockham-2-31037",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 528,
      "graphql_spend": 176
    },
    {
      "cycle": "20260831T062700Z-poetic-1-64354",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 376,
      "graphql_spend": 115
    },
    {
      "cycle": "20260831T063300Z-poetic-2-81250",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 397,
      "graphql_spend": 108
    },
    {
      "cycle": "20260831T063600Z-ockham-container-8667",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 462,
      "graphql_spend": 139
    },
    {
      "cycle": "20260831T063900Z-ockham-2-89",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 607,
      "graphql_spend": 148
    },
    {
      "cycle": "20260831T064200Z-poetic-1-2615",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 489,
      "graphql_spend": 127
    },
    {
      "cycle": "20260831T064800Z-poetic-2-3618",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 10,
      "graphql_spend": 2
    },
    {
      "cycle": "20260831T065100Z-ockham-container-6157",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 1,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T065400Z-ockham-2-23025",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 4,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T065700Z-poetic-1-22165",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 524,
      "graphql_spend": 122
    },
    {
      "cycle": "20260831T070300Z-poetic-2-23793",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 413,
      "graphql_spend": 131
    },
    {
      "cycle": "20260831T070600Z-ockham-container-16919",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 579,
      "graphql_spend": 139
    },
    {
      "cycle": "20260831T070900Z-ockham-2-7700",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 509,
      "graphql_spend": 121
    },
    {
      "cycle": "20260831T071200Z-poetic-1-42076",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 341,
      "graphql_spend": 104
    },
    {
      "cycle": "20260831T071800Z-poetic-2-42710",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 395,
      "graphql_spend": 101
    },
    {
      "cycle": "20260831T072100Z-ockham-container-7816",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 400,
      "graphql_spend": 126
    },
    {
      "cycle": "20260831T072400Z-ockham-2-26667",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 570,
      "graphql_spend": 134
    },
    {
      "cycle": "20260831T072700Z-poetic-1-61090",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 418,
      "graphql_spend": 101
    },
    {
      "cycle": "20260831T073300Z-poetic-2-61005",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 1182,
      "graphql_spend": 283
    },
    {
      "cycle": "20260831T073600Z-ockham-container-24957",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 640,
      "graphql_spend": 146
    },
    {
      "cycle": "20260831T073900Z-ockham-2-13723",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 526,
      "graphql_spend": 171
    },
    {
      "cycle": "20260831T074200Z-poetic-1-78938",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 799,
      "graphql_spend": 199
    },
    {
      "cycle": "20260831T074616Z-ockham-2-28940",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 10,
      "graphql_spend": 2
    },
    {
      "cycle": "20260831T074800Z-poetic-2-85018",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 47,
      "graphql_spend": 6
    },
    {
      "cycle": "20260831T075055Z-poetic-1-97470",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T075100Z-ockham-container-11722",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 13,
      "graphql_spend": 3
    },
    {
      "cycle": "20260831T075400Z-ockham-2-10698",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 4,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T075541Z-poetic-2-101257",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 714,
      "graphql_spend": 190
    },
    {
      "cycle": "20260831T075700Z-poetic-1-103742",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 584,
      "graphql_spend": 159
    },
    {
      "cycle": "20260831T080300Z-poetic-2-115133",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 650,
      "graphql_spend": 166
    },
    {
      "cycle": "20260831T080600Z-ockham-container-2151",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 527,
      "graphql_spend": 122
    },
    {
      "cycle": "20260831T080900Z-ockham-2-31565",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 386,
      "graphql_spend": 141
    },
    {
      "cycle": "20260831T081200Z-poetic-1-122764",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 321,
      "graphql_spend": 109
    },
    {
      "cycle": "20260831T081800Z-poetic-2-135509",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 374,
      "graphql_spend": 104
    },
    {
      "cycle": "20260831T082100Z-ockham-container-19560",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 412,
      "graphql_spend": 131
    },
    {
      "cycle": "20260831T082400Z-ockham-2-16972",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 378,
      "graphql_spend": 116
    },
    {
      "cycle": "20260831T082700Z-poetic-1-141296",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 494,
      "graphql_spend": 117
    },
    {
      "cycle": "20260831T083300Z-poetic-2-154035",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 420,
      "graphql_spend": 150
    },
    {
      "cycle": "20260831T083600Z-ockham-container-5993",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 612,
      "graphql_spend": 188
    },
    {
      "cycle": "20260831T083900Z-ockham-2-2895",
      "node": "ockham-2",
      "readings": 2,
      "core_spend": 667,
      "graphql_spend": 145
    },
    {
      "cycle": "20260831T084200Z-poetic-1-163188",
      "node": "poetic-1",
      "readings": 2,
      "core_spend": 427,
      "graphql_spend": 115
    },
    {
      "cycle": "20260831T084800Z-poetic-2-172711",
      "node": "poetic-2",
      "readings": 2,
      "core_spend": 2,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T085100Z-ockham-container-28986",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 33,
      "graphql_spend": 4
    },
    {
      "cycle": "20260831T085400Z-ockham-2-24050",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 9,
      "graphql_spend": 2
    },
    {
      "cycle": "20260831T085700Z-poetic-1-181638",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 559,
      "graphql_spend": 185
    },
    {
      "cycle": "20260831T085820Z-ockham-container-9773",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 424,
      "graphql_spend": 135
    },
    {
      "cycle": "20260831T090300Z-poetic-2-180725",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 1185,
      "graphql_spend": 260
    },
    {
      "cycle": "20260831T090503Z-ockham-container-21754",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 1113,
      "graphql_spend": 247
    },
    {
      "cycle": "20260831T090507Z-poetic-1-194419",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 1180,
      "graphql_spend": 283
    },
    {
      "cycle": "20260831T090900Z-ockham-2-7728",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 551,
      "graphql_spend": 169
    },
    {
      "cycle": "20260831T091430Z-poetic-1-214172",
      "node": "poetic-1",
      "readings": 3,
      "core_spend": 511,
      "graphql_spend": 134
    },
    {
      "cycle": "20260831T091800Z-poetic-2-202617",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 604,
      "graphql_spend": 189
    },
    {
      "cycle": "20260831T092100Z-ockham-container-14219",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 498,
      "graphql_spend": 165
    },
    {
      "cycle": "20260831T092400Z-ockham-2-24354",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 500,
      "graphql_spend": 140
    },
    {
      "cycle": "20260831T093300Z-poetic-2-222021",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 416,
      "graphql_spend": 170
    },
    {
      "cycle": "20260831T093600Z-ockham-container-446",
      "node": "ockham-container",
      "readings": 6,
      "core_spend": 689,
      "graphql_spend": 321
    },
    {
      "cycle": "20260831T093900Z-ockham-2-13657",
      "node": "ockham-2",
      "readings": 3,
      "core_spend": 342,
      "graphql_spend": 123
    },
    {
      "cycle": "20260831T094800Z-poetic-2-241214",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 10,
      "graphql_spend": 1
    },
    {
      "cycle": "20260831T095400Z-ockham-2-360",
      "node": "ockham-2",
      "readings": 6,
      "core_spend": 2367,
      "graphql_spend": 889
    },
    {
      "cycle": "20260831T100300Z-poetic-2-261583",
      "node": "poetic-2",
      "readings": 3,
      "core_spend": 341,
      "graphql_spend": 178
    },
    {
      "cycle": "20260831T101800Z-poetic-2-280294",
      "node": "poetic-2",
      "readings": 6,
      "core_spend": 2580,
      "graphql_spend": 961
    },
    {
      "cycle": "20260831T102632Z-ockham-container-30016",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 559,
      "graphql_spend": 177
    },
    {
      "cycle": "20260831T110600Z-ockham-container-17549",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 328,
      "graphql_spend": 189
    },
    {
      "cycle": "20260831T112100Z-ockham-container-6221",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 871,
      "graphql_spend": 258
    },
    {
      "cycle": "20260831T112955Z-ockham-container-20200",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 632,
      "graphql_spend": 245
    },
    {
      "cycle": "20260831T113843Z-ockham-container-8543",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 347,
      "graphql_spend": 157
    },
    {
      "cycle": "20260831T115100Z-ockham-container-27933",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20260831T115400Z-ockham-2-1083",
      "node": "ockham-2",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    }
  ],
  "per_node": [
    {
      "node": "ockham-2",
      "readings": 153,
      "unreadable": 0,
      "cycles_with_record": 50
    },
    {
      "node": "ockham-container",
      "readings": 189,
      "unreadable": 0,
      "cycles_with_record": 62
    },
    {
      "node": "poetic-1",
      "readings": 190,
      "unreadable": 0,
      "cycles_with_record": 62
    },
    {
      "node": "poetic-2",
      "readings": 231,
      "unreadable": 1,
      "cycles_with_record": 71
    }
  ],
  "refusals": 61,
  "budget_standdowns": 15,
  "shim": {
    "calls": 0,
    "hit": 0,
    "miss": 0,
    "stale": 0,
    "bypass": 0
  }
}
```
