# GitHub API budget report

328 readable reading(s) of 328, from 2026-10-02T00:08:55Z to 2026-10-03T02:58:52Z; 0 primary-limit refusal(s) reached guard-degraded and requirement 2.0 stood a cycle down 0 time(s).

Every figure is the *bucket's*: while every node authenticates as one user (D25
unprovisioned) the `x-ratelimit-*` headers describe the user's aggregate — the
fleet, the dashboard publisher and the owner's shell together — so a segment's
movement is an upper bound on what that segment itself spent.

## Per hour (UTC)

| hour | readings | core peak used | core min remaining | graphql peak used | refusals | budget stand-downs |
|---|---:|---:|---:|---:|---:|---:|
| 2026-10-02T00 | 15 | 203 | 4797 | 279 | 0 | 0 |
| 2026-10-02T01 | 5 | 150 | 4850 | 79 | 0 | 0 |
| 2026-10-02T02 | 10 | 224 | 4776 | 327 | 0 | 0 |
| 2026-10-02T03 | 9 | 795 | 4205 | 181 | 0 | 0 |
| 2026-10-02T04 | 12 | 303 | 4697 | 193 | 0 | 0 |
| 2026-10-02T05 | 16 | 222 | 4778 | 205 | 0 | 0 |
| 2026-10-02T06 | 12 | 384 | 4616 | 175 | 0 | 0 |
| 2026-10-02T07 | 9 | 529 | 4471 | 213 | 0 | 0 |
| 2026-10-02T08 | 13 | 239 | 4761 | 331 | 0 | 0 |
| 2026-10-02T09 | 10 | 195 | 4805 | 289 | 0 | 0 |
| 2026-10-02T10 | 13 | 218 | 4782 | 337 | 0 | 0 |
| 2026-10-02T11 | 11 | 159 | 4841 | 158 | 0 | 0 |
| 2026-10-02T12 | 14 | 192 | 4808 | 223 | 0 | 0 |
| 2026-10-02T13 | 20 | 773 | 4227 | 227 | 0 | 0 |
| 2026-10-02T14 | 9 | 691 | 4309 | 394 | 0 | 0 |
| 2026-10-02T15 | 11 | 303 | 4697 | 166 | 0 | 0 |
| 2026-10-02T16 | 9 | 280 | 4720 | 479 | 0 | 0 |
| 2026-10-02T17 | 23 | 365 | 4635 | 490 | 0 | 0 |
| 2026-10-02T18 | 12 | 258 | 4742 | 240 | 0 | 0 |
| 2026-10-02T19 | 13 | 274 | 4726 | 412 | 0 | 0 |
| 2026-10-02T20 | 12 | 215 | 4785 | 415 | 0 | 0 |
| 2026-10-02T21 | 8 | 215 | 4785 | 115 | 0 | 0 |
| 2026-10-02T22 | 9 | 321 | 4679 | 273 | 0 | 0 |
| 2026-10-02T23 | 15 | 365 | 4635 | 179 | 0 | 0 |
| 2026-10-03T00 | 9 | 277 | 4723 | 207 | 0 | 0 |
| 2026-10-03T01 | 9 | 337 | 4663 | 167 | 0 | 0 |
| 2026-10-03T02 | 20 | 890 | 4110 | 443 | 0 | 0 |

## Per stage (bucket movement while the stage ran; window rolls excluded)

| stage | readings | core median | core max | graphql median |
|---|---:|---:|---:|---:|
| approver | 11 | 21 | 220 | 41 |
| coordinator | 95 | 5 | 652 | 3 |
| enabler | 7 | 31 | 90 | 20 |
| enabler-decide | 2 | 4 | 4 | 3 |
| implementer | 20 | 7 | 37 | 11 |
| refiner | 13 | 21 | 280 | 23 |
| reviewer | 7 | 19 | 115 | 29 |

## Per cycle (core/graphql spent while that cycle ran; window rolls excluded)

| cycle | node | readings | core spend | graphql spend |
|---|---|---:|---:|---:|
| 20261001T225615Z-ockham-container-15740 | ockham-container | 6 | 115 | 166 |
| 20261001T234200Z-poetic-1-1981190 | poetic-1 | 5 | 41 | 5 |
| 20261002T002157Z-poetic-1-2448638 | poetic-1 | 7 | 40 | 27 |
| 20261002T012700Z-poetic-1-108 | poetic-1 | 8 | 91 | 49 |
| 20261002T013600Z-ockham-container-12672 | ockham-container | 7 | 72 | 6 |
| 20261002T030015Z-poetic-1-887441 | poetic-1 | 7 | 712 | 156 |
| 20261002T035236Z-poetic-1-1517851 | poetic-1 | 8 | 49 | 59 |
| 20261002T044011Z-ockham-container-14184 | ockham-container | 1 | 0 | 0 |
| 20261002T044412Z-ockham-container-1782 | ockham-container | 7 | 59 | 89 |
| 20261002T044414Z-poetic-1-965 | poetic-1 | 7 | 23 | 39 |
| 20261002T052539Z-poetic-1-458413 | poetic-1 | 7 | 87 | 49 |
| 20261002T054605Z-ockham-container-25338 | ockham-container | 9 | 48 | 49 |
| 20261002T061812Z-poetic-1-1076433 | poetic-1 | 8 | 249 | 148 |
| 20261002T070743Z-poetic-1-1617328 | poetic-1 | 9 | 379 | 171 |
| 20261002T081444Z-ockham-container-8257 | ockham-container | 7 | 147 | 176 |
| 20261002T085810Z-ockham-container-19264 | ockham-container | 8 | 16 | 12 |
| 20261002T091613Z-poetic-1-3049790 | poetic-1 | 1 | 0 | 0 |
| 20261002T092414Z-poetic-1-969 | poetic-1 | 6 | 30 | 47 |
| 20261002T100442Z-poetic-1-452708 | poetic-1 | 8 | 172 | 264 |
| 20261002T105617Z-poetic-1-1139750 | poetic-1 | 1 | 0 | 0 |
| 20261002T110413Z-poetic-1-968 | poetic-1 | 7 | 81 | 85 |
| 20261002T114814Z-poetic-1-963 | poetic-1 | 6 | 30 | 17 |
| 20261002T120014Z-ockham-container-1974 | ockham-container | 6 | 10 | 4 |
| 20261002T122700Z-poetic-1-437233 | poetic-1 | 6 | 16 | 10 |
| 20261002T123505Z-ockham-container-14293 | ockham-container | 7 | 113 | 12 |
| 20261002T130412Z-poetic-1-892964 | poetic-1 | 9 | 685 | 185 |
| 20261002T131206Z-ockham-container-30043 | ockham-container | 8 | 443 | 195 |
| 20261002T145102Z-ockham-container-18708 | ockham-container | 8 | 146 | 99 |
| 20261002T145352Z-poetic-1-1959897 | poetic-1 | 8 | 36 | 5 |
| 20261002T153814Z-poetic-1-2471086 | poetic-1 | 8 | 82 | 56 |
| 20261002T162615Z-ockham-container-27936 | ockham-container | 7 | 16 | 12 |
| 20261002T171245Z-ockham-container-10323 | ockham-container | 6 | 259 | 235 |
| 20261002T171724Z-poetic-1-3390163 | poetic-1 | 6 | 246 | 236 |
| 20261002T175448Z-ockham-container-28133 | ockham-container | 9 | 137 | 158 |
| 20261002T175616Z-poetic-1-3899328 | poetic-1 | 8 | 43 | 52 |
| 20261002T184841Z-poetic-1-240541 | poetic-1 | 7 | 34 | 53 |
| 20261002T192410Z-ockham-container-5254 | ockham-container | 8 | 34 | 29 |
| 20261002T194200Z-poetic-1-915724 | poetic-1 | 9 | 23 | 86 |
| 20261002T203813Z-poetic-1-1535648 | poetic-1 | 4 | 10 | 4 |
| 20261002T213014Z-ockham-container-5544 | ockham-container | 4 | 10 | 6 |
| 20261002T213414Z-poetic-1-967 | poetic-1 | 1 | 0 | 0 |
| 20261002T220414Z-poetic-1-977 | poetic-1 | 1 | 0 | 0 |
| 20261002T221415Z-ockham-container-1320 | ockham-container | 3 | 111 | 49 |
| 20261002T223414Z-poetic-1-968 | poetic-1 | 4 | 5 | 3 |
| 20261002T224413Z-ockham-container-1746 | ockham-container | 2 | 0 | 0 |
| 20261002T231413Z-ockham-container-2055 | ockham-container | 8 | 210 | 136 |
| 20261002T231817Z-poetic-1-975 | poetic-1 | 8 | 173 | 93 |
| 20261003T000424Z-ockham-container-2589 | ockham-container | 9 | 373 | 150 |
| 20261003T011200Z-poetic-1-24618 | poetic-1 | 1 | 0 | 0 |
| 20261003T011613Z-poetic-2-1006 | poetic-2 | 1 | 0 | 0 |
| 20261003T014200Z-poetic-1-190 | poetic-1 | 7 | 46 | 88 |
| 20261003T014214Z-poetic-2-1387 | poetic-2 | 4 | 7 | 9 |
| 20261003T022211Z-ockham-2-1119 | ockham-2 | 6 | 263 | 258 |
| 20261003T022614Z-ockham-container-15694 | ockham-container | 4 | 327 | 233 |
| 20261003T023414Z-poetic-1-638391 | poetic-1 | 1 | 0 | 0 |

## Per node

| node | readings | unreadable | cycles with a record |
|---|---:|---:|---:|
| ockham-2 | 6 | 0 | 1 |
| ockham-container | 134 | 0 | 21 |
| poetic-1 | 183 | 0 | 31 |
| poetic-2 | 5 | 0 | 2 |

## `gh` transport shim (requirement 2.0e)

Every `gh` call the ledger covers, by how the shim answered it: a conditional GET
served from a `304`, a fresh read, one served last-known-good under a refusal, or a
call the shim never caches at all (a write, `graphql`, or a caller reading its own
headers).

| calls | hit | miss | stale | bypass |
|---:|---:|---:|---:|---:|
| 29353 | 6314 | 12437 | 0 | 10602 |

```json
{
  "readings": 328,
  "readable": 328,
  "first_ts": "2026-10-02T00:08:55Z",
  "last_ts": "2026-10-03T02:58:52Z",
  "per_hour": [
    {
      "hour": "2026-10-02T00",
      "readings": 15,
      "core_peak_used": 203,
      "core_min_remaining": 4797,
      "graphql_peak_used": 279,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T01",
      "readings": 5,
      "core_peak_used": 150,
      "core_min_remaining": 4850,
      "graphql_peak_used": 79,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T02",
      "readings": 10,
      "core_peak_used": 224,
      "core_min_remaining": 4776,
      "graphql_peak_used": 327,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T03",
      "readings": 9,
      "core_peak_used": 795,
      "core_min_remaining": 4205,
      "graphql_peak_used": 181,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T04",
      "readings": 12,
      "core_peak_used": 303,
      "core_min_remaining": 4697,
      "graphql_peak_used": 193,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T05",
      "readings": 16,
      "core_peak_used": 222,
      "core_min_remaining": 4778,
      "graphql_peak_used": 205,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T06",
      "readings": 12,
      "core_peak_used": 384,
      "core_min_remaining": 4616,
      "graphql_peak_used": 175,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T07",
      "readings": 9,
      "core_peak_used": 529,
      "core_min_remaining": 4471,
      "graphql_peak_used": 213,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T08",
      "readings": 13,
      "core_peak_used": 239,
      "core_min_remaining": 4761,
      "graphql_peak_used": 331,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T09",
      "readings": 10,
      "core_peak_used": 195,
      "core_min_remaining": 4805,
      "graphql_peak_used": 289,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T10",
      "readings": 13,
      "core_peak_used": 218,
      "core_min_remaining": 4782,
      "graphql_peak_used": 337,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T11",
      "readings": 11,
      "core_peak_used": 159,
      "core_min_remaining": 4841,
      "graphql_peak_used": 158,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T12",
      "readings": 14,
      "core_peak_used": 192,
      "core_min_remaining": 4808,
      "graphql_peak_used": 223,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T13",
      "readings": 20,
      "core_peak_used": 773,
      "core_min_remaining": 4227,
      "graphql_peak_used": 227,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T14",
      "readings": 9,
      "core_peak_used": 691,
      "core_min_remaining": 4309,
      "graphql_peak_used": 394,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T15",
      "readings": 11,
      "core_peak_used": 303,
      "core_min_remaining": 4697,
      "graphql_peak_used": 166,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T16",
      "readings": 9,
      "core_peak_used": 280,
      "core_min_remaining": 4720,
      "graphql_peak_used": 479,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T17",
      "readings": 23,
      "core_peak_used": 365,
      "core_min_remaining": 4635,
      "graphql_peak_used": 490,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T18",
      "readings": 12,
      "core_peak_used": 258,
      "core_min_remaining": 4742,
      "graphql_peak_used": 240,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T19",
      "readings": 13,
      "core_peak_used": 274,
      "core_min_remaining": 4726,
      "graphql_peak_used": 412,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T20",
      "readings": 12,
      "core_peak_used": 215,
      "core_min_remaining": 4785,
      "graphql_peak_used": 415,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T21",
      "readings": 8,
      "core_peak_used": 215,
      "core_min_remaining": 4785,
      "graphql_peak_used": 115,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T22",
      "readings": 9,
      "core_peak_used": 321,
      "core_min_remaining": 4679,
      "graphql_peak_used": 273,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-02T23",
      "readings": 15,
      "core_peak_used": 365,
      "core_min_remaining": 4635,
      "graphql_peak_used": 179,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-03T00",
      "readings": 9,
      "core_peak_used": 277,
      "core_min_remaining": 4723,
      "graphql_peak_used": 207,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-03T01",
      "readings": 9,
      "core_peak_used": 337,
      "core_min_remaining": 4663,
      "graphql_peak_used": 167,
      "refusals": 0,
      "budget_standdowns": 0
    },
    {
      "hour": "2026-10-03T02",
      "readings": 20,
      "core_peak_used": 890,
      "core_min_remaining": 4110,
      "graphql_peak_used": 443,
      "refusals": 0,
      "budget_standdowns": 0
    }
  ],
  "per_stage": [
    {
      "stage": "approver",
      "readings": 11,
      "core_movement_median": 21,
      "core_movement_max": 220,
      "graphql_movement_median": 41
    },
    {
      "stage": "coordinator",
      "readings": 95,
      "core_movement_median": 5,
      "core_movement_max": 652,
      "graphql_movement_median": 3
    },
    {
      "stage": "enabler",
      "readings": 7,
      "core_movement_median": 31,
      "core_movement_max": 90,
      "graphql_movement_median": 20
    },
    {
      "stage": "enabler-decide",
      "readings": 2,
      "core_movement_median": 4,
      "core_movement_max": 4,
      "graphql_movement_median": 3
    },
    {
      "stage": "implementer",
      "readings": 20,
      "core_movement_median": 7,
      "core_movement_max": 37,
      "graphql_movement_median": 11
    },
    {
      "stage": "refiner",
      "readings": 13,
      "core_movement_median": 21,
      "core_movement_max": 280,
      "graphql_movement_median": 23
    },
    {
      "stage": "reviewer",
      "readings": 7,
      "core_movement_median": 19,
      "core_movement_max": 115,
      "graphql_movement_median": 29
    }
  ],
  "per_cycle": [
    {
      "cycle": "20261001T225615Z-ockham-container-15740",
      "node": "ockham-container",
      "readings": 6,
      "core_spend": 115,
      "graphql_spend": 166
    },
    {
      "cycle": "20261001T234200Z-poetic-1-1981190",
      "node": "poetic-1",
      "readings": 5,
      "core_spend": 41,
      "graphql_spend": 5
    },
    {
      "cycle": "20261002T002157Z-poetic-1-2448638",
      "node": "poetic-1",
      "readings": 7,
      "core_spend": 40,
      "graphql_spend": 27
    },
    {
      "cycle": "20261002T012700Z-poetic-1-108",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 91,
      "graphql_spend": 49
    },
    {
      "cycle": "20261002T013600Z-ockham-container-12672",
      "node": "ockham-container",
      "readings": 7,
      "core_spend": 72,
      "graphql_spend": 6
    },
    {
      "cycle": "20261002T030015Z-poetic-1-887441",
      "node": "poetic-1",
      "readings": 7,
      "core_spend": 712,
      "graphql_spend": 156
    },
    {
      "cycle": "20261002T035236Z-poetic-1-1517851",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 49,
      "graphql_spend": 59
    },
    {
      "cycle": "20261002T044011Z-ockham-container-14184",
      "node": "ockham-container",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261002T044412Z-ockham-container-1782",
      "node": "ockham-container",
      "readings": 7,
      "core_spend": 59,
      "graphql_spend": 89
    },
    {
      "cycle": "20261002T044414Z-poetic-1-965",
      "node": "poetic-1",
      "readings": 7,
      "core_spend": 23,
      "graphql_spend": 39
    },
    {
      "cycle": "20261002T052539Z-poetic-1-458413",
      "node": "poetic-1",
      "readings": 7,
      "core_spend": 87,
      "graphql_spend": 49
    },
    {
      "cycle": "20261002T054605Z-ockham-container-25338",
      "node": "ockham-container",
      "readings": 9,
      "core_spend": 48,
      "graphql_spend": 49
    },
    {
      "cycle": "20261002T061812Z-poetic-1-1076433",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 249,
      "graphql_spend": 148
    },
    {
      "cycle": "20261002T070743Z-poetic-1-1617328",
      "node": "poetic-1",
      "readings": 9,
      "core_spend": 379,
      "graphql_spend": 171
    },
    {
      "cycle": "20261002T081444Z-ockham-container-8257",
      "node": "ockham-container",
      "readings": 7,
      "core_spend": 147,
      "graphql_spend": 176
    },
    {
      "cycle": "20261002T085810Z-ockham-container-19264",
      "node": "ockham-container",
      "readings": 8,
      "core_spend": 16,
      "graphql_spend": 12
    },
    {
      "cycle": "20261002T091613Z-poetic-1-3049790",
      "node": "poetic-1",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261002T092414Z-poetic-1-969",
      "node": "poetic-1",
      "readings": 6,
      "core_spend": 30,
      "graphql_spend": 47
    },
    {
      "cycle": "20261002T100442Z-poetic-1-452708",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 172,
      "graphql_spend": 264
    },
    {
      "cycle": "20261002T105617Z-poetic-1-1139750",
      "node": "poetic-1",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261002T110413Z-poetic-1-968",
      "node": "poetic-1",
      "readings": 7,
      "core_spend": 81,
      "graphql_spend": 85
    },
    {
      "cycle": "20261002T114814Z-poetic-1-963",
      "node": "poetic-1",
      "readings": 6,
      "core_spend": 30,
      "graphql_spend": 17
    },
    {
      "cycle": "20261002T120014Z-ockham-container-1974",
      "node": "ockham-container",
      "readings": 6,
      "core_spend": 10,
      "graphql_spend": 4
    },
    {
      "cycle": "20261002T122700Z-poetic-1-437233",
      "node": "poetic-1",
      "readings": 6,
      "core_spend": 16,
      "graphql_spend": 10
    },
    {
      "cycle": "20261002T123505Z-ockham-container-14293",
      "node": "ockham-container",
      "readings": 7,
      "core_spend": 113,
      "graphql_spend": 12
    },
    {
      "cycle": "20261002T130412Z-poetic-1-892964",
      "node": "poetic-1",
      "readings": 9,
      "core_spend": 685,
      "graphql_spend": 185
    },
    {
      "cycle": "20261002T131206Z-ockham-container-30043",
      "node": "ockham-container",
      "readings": 8,
      "core_spend": 443,
      "graphql_spend": 195
    },
    {
      "cycle": "20261002T145102Z-ockham-container-18708",
      "node": "ockham-container",
      "readings": 8,
      "core_spend": 146,
      "graphql_spend": 99
    },
    {
      "cycle": "20261002T145352Z-poetic-1-1959897",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 36,
      "graphql_spend": 5
    },
    {
      "cycle": "20261002T153814Z-poetic-1-2471086",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 82,
      "graphql_spend": 56
    },
    {
      "cycle": "20261002T162615Z-ockham-container-27936",
      "node": "ockham-container",
      "readings": 7,
      "core_spend": 16,
      "graphql_spend": 12
    },
    {
      "cycle": "20261002T171245Z-ockham-container-10323",
      "node": "ockham-container",
      "readings": 6,
      "core_spend": 259,
      "graphql_spend": 235
    },
    {
      "cycle": "20261002T171724Z-poetic-1-3390163",
      "node": "poetic-1",
      "readings": 6,
      "core_spend": 246,
      "graphql_spend": 236
    },
    {
      "cycle": "20261002T175448Z-ockham-container-28133",
      "node": "ockham-container",
      "readings": 9,
      "core_spend": 137,
      "graphql_spend": 158
    },
    {
      "cycle": "20261002T175616Z-poetic-1-3899328",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 43,
      "graphql_spend": 52
    },
    {
      "cycle": "20261002T184841Z-poetic-1-240541",
      "node": "poetic-1",
      "readings": 7,
      "core_spend": 34,
      "graphql_spend": 53
    },
    {
      "cycle": "20261002T192410Z-ockham-container-5254",
      "node": "ockham-container",
      "readings": 8,
      "core_spend": 34,
      "graphql_spend": 29
    },
    {
      "cycle": "20261002T194200Z-poetic-1-915724",
      "node": "poetic-1",
      "readings": 9,
      "core_spend": 23,
      "graphql_spend": 86
    },
    {
      "cycle": "20261002T203813Z-poetic-1-1535648",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 10,
      "graphql_spend": 4
    },
    {
      "cycle": "20261002T213014Z-ockham-container-5544",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 10,
      "graphql_spend": 6
    },
    {
      "cycle": "20261002T213414Z-poetic-1-967",
      "node": "poetic-1",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261002T220414Z-poetic-1-977",
      "node": "poetic-1",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261002T221415Z-ockham-container-1320",
      "node": "ockham-container",
      "readings": 3,
      "core_spend": 111,
      "graphql_spend": 49
    },
    {
      "cycle": "20261002T223414Z-poetic-1-968",
      "node": "poetic-1",
      "readings": 4,
      "core_spend": 5,
      "graphql_spend": 3
    },
    {
      "cycle": "20261002T224413Z-ockham-container-1746",
      "node": "ockham-container",
      "readings": 2,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261002T231413Z-ockham-container-2055",
      "node": "ockham-container",
      "readings": 8,
      "core_spend": 210,
      "graphql_spend": 136
    },
    {
      "cycle": "20261002T231817Z-poetic-1-975",
      "node": "poetic-1",
      "readings": 8,
      "core_spend": 173,
      "graphql_spend": 93
    },
    {
      "cycle": "20261003T000424Z-ockham-container-2589",
      "node": "ockham-container",
      "readings": 9,
      "core_spend": 373,
      "graphql_spend": 150
    },
    {
      "cycle": "20261003T011200Z-poetic-1-24618",
      "node": "poetic-1",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261003T011613Z-poetic-2-1006",
      "node": "poetic-2",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    },
    {
      "cycle": "20261003T014200Z-poetic-1-190",
      "node": "poetic-1",
      "readings": 7,
      "core_spend": 46,
      "graphql_spend": 88
    },
    {
      "cycle": "20261003T014214Z-poetic-2-1387",
      "node": "poetic-2",
      "readings": 4,
      "core_spend": 7,
      "graphql_spend": 9
    },
    {
      "cycle": "20261003T022211Z-ockham-2-1119",
      "node": "ockham-2",
      "readings": 6,
      "core_spend": 263,
      "graphql_spend": 258
    },
    {
      "cycle": "20261003T022614Z-ockham-container-15694",
      "node": "ockham-container",
      "readings": 4,
      "core_spend": 327,
      "graphql_spend": 233
    },
    {
      "cycle": "20261003T023414Z-poetic-1-638391",
      "node": "poetic-1",
      "readings": 1,
      "core_spend": 0,
      "graphql_spend": 0
    }
  ],
  "per_node": [
    {
      "node": "ockham-2",
      "readings": 6,
      "unreadable": 0,
      "cycles_with_record": 1
    },
    {
      "node": "ockham-container",
      "readings": 134,
      "unreadable": 0,
      "cycles_with_record": 21
    },
    {
      "node": "poetic-1",
      "readings": 183,
      "unreadable": 0,
      "cycles_with_record": 31
    },
    {
      "node": "poetic-2",
      "readings": 5,
      "unreadable": 0,
      "cycles_with_record": 2
    }
  ],
  "refusals": 0,
  "budget_standdowns": 0,
  "shim": {
    "calls": 29353,
    "hit": 6314,
    "miss": 12437,
    "stale": 0,
    "bypass": 10602
  }
}
```
