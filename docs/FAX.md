# The fax system

Every paper screen in the game is the same dot-matrix fax machine (`scripts/fax_printer.gd`: layout,
paper, printer, rules, stamps, LCD) and moves the same way. Polished 2026-09-17 (fax-polish).

## The motions

| Motion | Easing | Time | Constant |
|---|---|---|---|
| A page arrives: feeds **up** out of the slot and slows to a stop | ease out (cubic) | 0.5 s | `Fax.FEED_SECONDS` |
| A page is done / torn off: accelerates **up** off the top | ease in (moving from the first frame) | 0.35 s | `Fax.EJECT_SECONDS` |
| The machine appears: rises in from below the screen | ease out | 0.38 s | `Fax.RISE_SECONDS` |
| The machine goes: sinks off the bottom | ease in | 0.38 s | `Fax.DROP_SECONDS` |

Rules:

- The printer only moves when the machine itself appears or goes (pause, pharmacy form, end of the
  shift assignment). Pages that follow each other swap in the same standing printer: the old page
  ejects, then the next feeds (title <-> settings <-> shift assignment, launch -> title).
- A page leaves from wherever it is. Sending a half-fed sheet away, or calling the pause page / the
  pharmacy form back while it is still leaving, turns the motion around (`Fax.Motion`), no jumps.
- Text is only ever drawn on paper that is there: sheets are clipped to the paper above the slot.
- Input: pages answer clicks and focus only while up. Closing gives control back the same frame
  (pause, pharmacy); the page and printer animate away over the game.
- Animation time is real time (dev slow motion doesn't slow it), at most `Fax.MAX_STEP` per frame.
- Headless (tests), every motion is instant; `is_open()` / `holds_input()` flip at once.
- Sounds: `print_feed` when a page feeds (motor ticks every `Fax.FEED_TICK`), ejects or tears off,
  `print_line` when a line prints, `print_stamp` on stamps and tick boxes, `fax_connect` at launch and
  when an order is sent.

## Every usage and transition

Timings are wall clock from `tools/faxshot.tscn -- --timing` (1280x720, Radeon 890M); "before" is what
the old constants added up to.

| Transition | Motion now | Now | Before |
|---|---|---|---|
| Launch printout (`launch_screen.gd`) prints the chart | covers the warmup, paced by it; stamped page held >= 0.9 s | warmup | stamp held >= 1.3 s |
| Launch -> title | stamped page ejects, sign-in sheet feeds in (`menu.feed_in`) | 0.95 s | 2.1 s |
| Title -> settings | sign-in sheet ejects, settings page feeds | 0.85 s | 1.5 s |
| Settings -> title (Back / Esc) | settings page ejects, fresh sign-in sheet feeds | 0.85 s | 1.8 s |
| Title -> shift start (solo / host / Steam / join) | sign-in sheet ejects, SHIFT ASSIGNMENT feeds; loading starts once the sheet is gone | 0.35 s + 0.5 s | 0.5 s + 1.3 s |
| Shift assignment, world ready -> player in (`shift_fax.gd`) | frames settle (>= 0.3 s), room fades part way while GOOD LUCK... types, 0.25 s beat, page ejects + printer sinks + room fades out. Mouse and keys return as the page starts leaving | ~1.4-1.8 s (control at ~1.0-1.4 s) | ~5 s (control at the end) |
| Join / host failure -> title | assignment ejects (from wherever it is), fresh sign-in sheet feeds with the reason | 0.85 s | 1.8 s |
| Pause open (Esc, `settings_screen.gd`) | printer rises; page feeds up out of its slot from 30% of the rise. Controls live at once | 0.61 s | 0.75 s (page came down from the top) |
| Pause close (Esc / Resume) | control back the same frame; page ejects while printer sinks | 0.38 s | 0.55 s, paused until done |
| Pause mashing Esc | reopening while it leaves turns the same page and printer around | - | restarted |
| Pause -> Main menu | session torn down, title room + printer take over in place, pause page ejects, sign-in sheet feeds (`leave_to_menu`, `menu.hold_in_printer`) | 0.87 s | instant pop |
| Pause -> Quit game | quits at once | 0 | 0 |
| Tip memo (`tips/tip_fax.gd`) appears | little machine rises; paper slides up out of the slot as lines print (no line-at-a-time jumps) | 0.3 s + printing | same, paper jumped per line |
| Tip memo torn off (Esc, or after 20 s) | memo flies up and fades; machine sinks from half way through (if nothing is queued) | 0.48 s | 0.75 s |
| Next queued memo | the machine stays up, the next memo prints | - | - |
| Pharmacy order form open (E, `economy/fax_order_ui.gd`) | machine rises, blank form feeds up. Controls live at once | 0.61 s | instant pop |
| Pharmacy Esc / CANCEL | control back at once; form ejects while machine sinks. E again before it has gone brings the same form back | 0.38 s | instant |
| Pharmacy SEND FAX | form locked, pulled down into the machine (0.6 s), order sent, control back, machine sinks | 0.97 s (control at 0.6 s) | 1.1 s then instant |
| Secret dev order reply | reply page prints line by line up out of the slot (0.3 s a line), waits on the dev room, holds 1.2 s, ejects + machine sinks | ~4 s + build | ~6.5 s + build, then instant |
| Session ends under an open page (host left, died at the pharmacy) | page vanishes with the session (nothing to animate over) | 0 | 0 |

Not fax screens: the in-world pharmacy fax and terminal props (`economy_props.gd`,
`fax_terminal.gd`) only play 3D print sounds. The break room case printer and case sheet reader were
removed with the wall terminal (KNOWN_ISSUES, 2026-09-16).

## Checking it

`tools/faxshot.tscn` (windowed) drives every transition above, logs wall-clock durations and saves a
contact sheet of frames per transition to `tools/fax_shots/`. `-- --timing` skips the frames for
honest timings; `-- --menu-only` stops after the title screens. Headless it runs as a quick smoke test
of the logic (every motion is instant there).
