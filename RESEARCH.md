# RESEARCH — Phase 1 (2026-10-11)

Research and license check for a JIT-less GameCube emulator on the iOS App Store. This is not legal advice. Items marked **Risk** should get a real lawyer's eyes before launch if revenue is meaningful.

---

## 1. Are GameCube emulators on the App Store right now?

| App | Seller | GameCube claim | Model | Assessment |
|---|---|---|---|---|
| **Provenance** (id1596862805) | Joseph Mattiello | Yes, via a "Dolphin (JIT-less)" core. The wiki says only Wii is excluded from the App Store build, so GameCube is included | Free, with "Provenance Plus" IAP at $3.99 / $39.99 / $99.99 | **Legitimate**, open source. This is the closest precedent for us: JIT-less Dolphin, GameCube, App Store, and paid IAP. Its wiki flags GameCube as "⚠️ Demanding." |
| **Fin – Game Emulator** (id6758910777) | Dylan Mathurin | Claims GameCube, Wii, Wii U, 3DS, Triforce | Free plus 10 IAPs (premium, ad removal, donations) | **Unverified.** It looks like it runs, with 4.1★ from 482 ratings and reviewers reporting GameCube/Wii working. I found no published source or GPL notice. If it uses Dolphin or Cemu code without releasing source, that's a GPL problem for them, not us. |
| **Gamuroid: All Game Emulator** (id6749228186) | UNIVERSAL TECHLAB | Claims GameCube, Wii, PS2, 3DS | Weekly $3.99–$4.99, monthly $9.99, "lifetime" $29.99–$39.99 | **Red flags.** Weekly subscriptions, heavy ads, no review confirming GameCube works, and boilerplate developer replies that reviewers suspect are bots. Treat it as low-quality or predatory. |
| **"Dolphin Emulator – Basic"** (id6742373017) | Irene Klein | No, it's NES only despite the name | $2.99/month subscription | **Copycat or misleading.** It uses the Dolphin name without being Dolphin. 2.0★, with "rip-off" and "doesn't work" reviews. |
| DolphiniOS | OatmealDome | — | Sideload only | Not on the App Store. Its developers say an App Store release is "simply not a good idea at the moment" because of JIT-less performance. |
| iCube | Provenance team | — | Sideload / TestFlight | Its site says "iCube isn't on the App Store." The repo has a `testflight.yml` CI workflow and an `iCube AppStore.entitlements` file, so an App Store release may be coming. **That would make it a direct competitor.** |

**Takeaway:** a JIT-less Dolphin GameCube app on the App Store already exists (Provenance). Apple has accepted the concept, so we're not first. What would set us apart is **performance, polish, and a dedicated GameCube experience.**

Sources:
- https://apps.apple.com/us/app/provenance-app/id1596862805
- https://wiki.provenance-emu.com/platforms-and-performance/supported-systems
- https://provenance-emu.com/systems/gamecube/
- https://apps.apple.com/us/app/fin-game-emulator/id6758910777
- https://apps.apple.com/us/app/gamuroid-all-game-emulator/id6749228186
- https://apps.apple.com/us/app/dolphin-emulator-basic/id6742373017
- https://icube-emu.com/
- https://oatmealdome.me/?p=1695 (DolphiniOS 4.0.0b8, Jan 18 2025)

---

## 2. Source code and licenses

| Project | Repo | License | Activity (GitHub API, 2026-10-11) |
|---|---|---|---|
| **Dolphin** (upstream) | https://github.com/dolphin-emu/dolphin | **GPL-2.0-or-later** for most code. Per-file SPDX tags; `LICENSES/` also has BSD-3-Clause, MIT, CC0-1.0. COPYING says the whole repo "in aggregate … is compatible with the GPLv3 license." | Pushed 2026-10-10; latest release tag `2609` |
| **DolphiniOS** | https://github.com/OatmealDome/dolphin-ios | Same as Dolphin (GPL-2.0-or-later) | Pushed 2026-06-20 |
| **iCube** (Provenance) | https://github.com/Provenance-Emu/iCube (forked from brand175/dolphin-ios; the old `Provenance-Emu/dolphin-ios-jitless` URL now redirects here) | Same `COPYING` and `LICENSES/` as Dolphin. Every Cached Interpreter file I checked is `SPDX-License-Identifier: GPL-2.0-or-later`. The app's Swift code is headed `Copyright … DolphiniOS Project / GPL-2.0-or-later`. Some Swift files have **no header** (e.g. `TVMultilineTextView.swift`, `PVWebServer` tests). | Pushed 2026-10-11. **100 commits in the last 3 days, all by Joseph Mattiello.** Very active, single maintainer. |
| iCube Dolphin base | https://github.com/JoeMatt/dolphin | GPL-2.0-or-later | Pushed 2026-09-23 |

**Can we legally fork iCube?** **Yes.** GPL-2.0-or-later allows forking, modifying, and selling, as long as we follow the GPL (section 4). We can't relicense it, and the whole app we ship is a derivative work under GPL.

Caveats:
- Files without license headers fall under the repository's license by implication. That's slightly ambiguous, so we'll avoid those files or rewrite them. We're replacing iCube's UI anyway.
- iCube bundles Nintendo-style controller art (`wiimote_plus*.png`) and other assets. **We must not reuse any of them.** We'll take only the emulation core.
- iCube's own entitlement files include `allow-jit`, `allow-unsigned-executable-memory`, `get-task-allow`, and private entitlements. We'll use none of them (see Phase 3).

Sources:
- https://github.com/dolphin-emu/dolphin/blob/master/COPYING
- https://github.com/Provenance-Emu/iCube
- https://icube-emu.com/licenses/
- https://provenance.itch.io/icube

---

## 3. How JIT-less Dolphin works, and which base to use

**Background.** GameCube games are PowerPC code, and the iPhone is ARM64. Dolphin has three CPU backends:
1. **JIT recompiler** (JitArm64). Translates PowerPC blocks into native ARM code. Fastest, but it needs writable and executable memory, which the App Store doesn't allow.
2. **Interpreter.** Decodes and runs one instruction at a time. Very slow.
3. **Cached Interpreter.** Decodes each block once and caches a list of pre-decoded handler calls, so later runs skip decoding. It writes no machine code, so it's **allowed on the App Store**. This is the backend we use.

**How fast is it today?**
- Mainline Dolphin: the DolphiniOS developers wrote (Jan 2025) that "the Cached Interpreter is unable to reach full speed with default settings, even on high-end gaming PCs." Mario Kart Wii ran at "~30fps (50% speed) on the iPhone 16 Pro Max." (https://oatmealdome.me/?p=1695)
- Upstream has kept improving it, e.g. "Cached Interpreter: Speculative devirtualization" (TellowKrinkle, 2025-09).
- **iCube** advertises "better performance than any other Dolphin version without JIT" and "faster than the mainline project's non-JIT cached interpreter," recommending A12+ (https://provenance.itch.io/icube). It gives no benchmark numbers.

**What iCube has done to the Cached Interpreter** (from its commit log, `Source/Core/Core/PowerPC/CachedInterpreter/`):
- A new **IR layer** (`CachedInterpreterIR.cpp/.h`) and emitter rework.
- **NEON paired-single fast paths** ("PsNeon"). The GameCube CPU's paired-single float math maps onto ARM NEON.
- **Instruction fusion**, e.g. merging the byte-copy runs that feed the graphics FIFO ("fuse gather-pipe byte-copy runs", 2026-09-22).
- A **global indirect-branch target cache**. Return-instruction hit rate went from 73% to 99.6% (2026-09-23).
- Per-opcode profiling counters, which are useful for us in Phase 4.
- Some fixes for "stale dynamic-link fill corrupted reused tape." This is new, aggressive code that's still fixing correctness bugs.

**Other JIT-less tricks** (for Phase 4): turning the main dispatch loop into threaded code with `[[clang::musttail]]` so handlers chain directly; block linking without going back to the dispatcher; fast paths for memory access when the address hits plain RAM (skipping MMIO); NEON for paired singles; skipping idle loops; VBI Skip for frame pacing (Dolphin and iCube); and GPU-side ubershaders to avoid shader-compile stutter.

**iOS 26 / 27 and JIT.** In my search I found no official Apple change to JIT for third-party apps. App Store apps still get **no** JIT entitlement on iOS.
- Since iOS 26 the TXM security monitor "will not execute a freshly written code page until a debugger has written to that page" (iCube README). Sideloaded apps can only get JIT through a debugger such as StikDebug or Xcode. Community docs say iOS 27 works "the same as 26."
- None of that applies to the App Store. **Our app must assume JIT never exists.**
- Sources: https://github.com/Provenance-Emu/iCube, https://docs.sidestore.io/docs/advanced/jit, https://builds.io/blog/technologies/ios-technologies/how-to-enable-jit-on-iphone/

**Memory.**
- `com.apple.developer.kernel.increased-memory-limit` is a documented, public entitlement (iOS 15+). A DTS reply in Apple's forums says it isn't in Xcode's Signing & Capabilities editor and has to be enabled in the developer portal, which probably means a **paid** account (not yet verified). iCube uses it.
- `extended-virtual-addressing` is also used by iCube. Results reported in Apple's forums are mixed.
- We'll look at both in Phase 7. A GameCube has only 24 MB of main RAM plus 16 MB of audio RAM, so our real memory use is caches, textures, and the block cache. That's manageable.
- Sources: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit, https://developer.apple.com/forums/thread/770868

### Base options

| Option | Pros | Cons |
|---|---|---|
| **A. Fork iCube, keep its core, replace its app** | Fastest JIT-less CPU core available. Already builds for iOS (CMake to `PVlibDolphin.xcframework`). It tracks upstream. | Moves very fast with one maintainer, so merges will be painful and new bugs show up. It carries Wii code, Provenance branding and assets, JIT code, and a Tuist app we don't want. |
| **B. Upstream Dolphin + cherry-pick iCube's Cached Interpreter work** | Cleanest and most stable base, with a stable merge path. | iCube's core patches may be tangled with its iOS host code. More work at the start. Slower until the ports land. |
| **C. DolphiniOS** | Mature iOS port. | Older UIKit app. Less JIT-less work than iCube. Its authors are focused on JIT for sideloading. |

---

## 4. GPL obligations for a paid App Store app

Our app links Dolphin's core, so **the whole app (including our Swift UI and purchase code) is covered by GPL-2.0-or-later.**

What we must do:
1. **Publish the complete corresponding source** for every version we ship: core, Swift app, build scripts, and project files. That means a public repo tagged per App Store build.
2. **Show license notices in the app**: GPL text, copyright notices for Dolphin and iCube, and every bundled third-party license (Settings > Acknowledgements).
3. **Add no further restrictions** on the GPL code (GPLv2 §6).
4. Mark modified files with notices of change (GPLv2 §2a). Git history plus file headers covers this.
5. **Keep it GPL-2.0-or-later, not GPLv3.** COPYING says the repo as a whole is "compatible with GPLv3," so some bundled third-party piece may be GPLv3. GPLv3 §6 requires "Installation Information" for consumer devices like iPhones, which we can't really provide. **Action (Phase 2/3):** audit the SPDX tags of everything we actually link and exclude anything GPLv3-only.

Charging money:
- GPL allows charging for copies and for features. A $2.99 IAP unlock is allowed.
- **Anyone can build the source and remove the paywall**, and that's legal. iCube says outright that self-built copies "include every Plus feature at no cost."
- The purchase really pays for convenience, App Store distribution, and updates. Plan the business around that.

**Risk — App Store terms vs. GPL:**
- In 2011, VLC was pulled from the App Store after one of its copyright holders complained that Apple's usage rules add restrictions the GPL forbids. Apple removed it on that complaint.
- Since then, many GPL apps have shipped without trouble: RetroArch, PPSSPP, and Provenance (Dolphin core, App Store, paid IAP).
- **The real risk is a takedown request from any Dolphin or iCube copyright holder.** Dolphin has hundreds of contributors.
- Mitigations:
  - Publish complete source from day one.
  - Use a custom EULA in App Store Connect that states the GPL governs the code.
  - Don't use the "Dolphin" or "iCube" names in marketing; credit them in Acknowledgements.
  - Be a good citizen: contribute fixes upstream and credit iCube prominently.
  - Optionally contact the iCube maintainer before launch.
- Sources: https://www.engadget.com/2011-01-09-the-gpl-the-app-store-and-you.html, https://www.osnews.com/story/23977/copyright-infringement-claim-filed-to-apple-over-vlc/

**Risk — Nintendo:**
- In 2023 Nintendo blocked Dolphin's Steam release by citing the **Wii Common Key**, an encryption key embedded in Dolphin's source.
- Dolphin kept the key after legal advice, but Nintendo clearly targets it.
- **Our ground rules forbid bundling keys.** Since we're GameCube-only, we should **strip Wii support and remove the key from our source tree and binary.** GameCube discs aren't encrypted, so we don't need it.
- `verify_no_jit.sh` will also check that the key bytes are absent.
- Sources: https://www.thesixthaxis.com/2023/05/30/dolphin-emulator-steam-release-blocked-by-nintendo-dmca-notice/, https://www.gamingonlinux.com/2023/07/dolphin-emulator-devs-give-up-on-steam-release/page=2

---

## 5. App Review Guidelines that apply to us

Source: https://developer.apple.com/app-store/review/guidelines/ (fetched 2026-10-11).

**4.7 (game emulators):**
- "retro game console and PC emulator apps can offer to download games," and the developer is responsible for that content.
- 4.7.1–4.7.5 (filtering, index of software with universal links, age gating) apply to **software offered in the app**.
- **We offer no games.** Users import their own files, so we avoid most of 4.7.x. We'll still say so explicitly in the review notes.

**2.5.2 (no downloading or executing code that changes functionality):**
- Interpreting the user's own game files is how every App Store emulator works, and 4.7 explicitly covers emulators.
- No JIT is consistent with this. Apple gives third-party iOS apps no JIT entitlement.
- The guidelines don't mention JIT by name.

**3.1.1 (in-app purchase):**
- "If you want to unlock features or functionality… unlocking a full version… you must use in-app purchase." ✅ We use a non-consumable StoreKit IAP.
- "make sure you have a restore mechanism for any restorable in-app purchases." ✅ Restore Purchases goes in Settings and on the unlock screen.
- Trials: "Non-subscription apps may offer a free time-based trial period … by setting up a Non-Consumable IAP item at Price Tier 0 that follows the naming convention: 'XX-day Trial.' Prior to the start of the trial, your app must clearly identify its duration, the content or services that will no longer be accessible when the trial ends, and any downstream charges."
- **Flag:** our "10 minutes per session, unlimited sessions" model isn't the "XX-day Trial" kind of trial. It's really a **feature-limited free tier** (a demo-style limit), which 3.1.1 allows as long as the unlock is IAP. Recommendations:
  - **Don't call it a "free trial"** in App Store Connect or the app. Call it something like "Free play: 10-minute sessions," and "Unlock unlimited play — $2.99, one time."
  - Before the first GameCube session, clearly show the 10-minute limit, what happens at the limit (pause + save), and the one-time price.
  - Don't create a $0 "Trial" IAP.
  - Make sure the free tier is useful on its own: the library, settings, and full 10-minute sessions.

**5.2.1 (intellectual property):**
- "Don't use protected third-party material such as trademarks… and don't include misleading, false, or copycat representations, names, or metadata."
- → No "Nintendo," "GameCube," "Dolphin," or "iCube" in the app name or icon. "GameCube" is a Nintendo trademark, so it can appear in the description only as a plain compatibility statement, e.g. "plays your own GameCube™ game backups." Even that is a gray area; we'll review it in Phase 7.
- **Flag on the user's spec:** the IAP is named "Full **GameCube** Unlock." A safer name is "Unlock Full Version" or "Unlimited Play."

**4.1 (copycats) / 5.2.1:** the original UI requirement in our plan covers this. Keep the Nintendo-trade-dress checklist in Phase 5.

---

## Recommendation (for CHECKPOINT 1)

**Base: Option A, modified. Fork iCube for its JIT-less core, build our own app, and keep upstream Dolphin as a second remote.**
1. Fork `Provenance-Emu/iCube` at a known-good commit into `~/Projects/gc-emu`. Add `dolphin-emu/dolphin` as an extra remote.
2. Use only the core (`Source/Core` + `Externals`) built as an xcframework. Drop iCube's Tuist app, assets, Wii/tvOS targets, and JIT backends.
3. Build our own SwiftUI shell later (Phases 5–6), structured as a "core plugin" interface so the 3DS core can be added the same way.
4. Pin to tested iCube commits rather than tracking `develop` live. Pull its Cached Interpreter improvements in deliberately, with A/B benchmarks.
5. Strip Wii support and the Wii common key. Audit licenses to stay GPL-2.0-or-later.

**Why:**
- Performance is the top priority, and iCube's Cached Interpreter is the fastest JIT-less Dolphin available.
- Its license (GPL-2.0-or-later) allows exactly this.
- Pinning plus the upstream remote reduces the single-maintainer churn risk.

**Honest expectation:** even iCube's core probably **won't run every game at full speed on every iPhone.** The demanding games will need speed hacks and recent chips (A17 Pro / A18 / A19 class). Phase 4's benchmarks will show how close we get. The App Store page and the trial's FPS overlay will need to set expectations honestly.

**Decisions needed from you:**
1. Approve the base (A as modified above, B, or C).
2. Approve **GameCube-only** (strip Wii and its key). Recommended.
3. Rename the IAP from "Full GameCube Unlock" to a name without "GameCube," and frame the 10-minute limit as "free play sessions" rather than a "free trial."

## Phase 6: Guideline 3.1.1 wording review (2026-10-12)
Source: Apple's App Review Guidelines (developer.apple.com/app-store/review/guidelines), 3.1.1 / 3.1.2 / 2.1.

- **Model:** free download; every game launch is a free 10-minute play session (unlimited sessions,
  never expires); one non-consumable "Unlock Full Version" ($2.99) removes the limit and the forced
  FPS/speed readout. This is a limited free version, not a time-based trial: nothing expires or is
  taken away, so the "XX-day Trial" Price Tier 0 item that 3.1.1 asks of *time-based trials* doesn't
  apply. The word "trial" is never used in the app or metadata.
- **Disclosure before and during play:** a toast at the start of each session ("Free play session:
  10 minutes. Unlock the full version for unlimited play."), a warning 1 minute before the end, and
  the unlock screen that states exactly what the purchase adds, that it's one-time (no subscription,
  no ads), and that free sessions stay available ("Not now").
- **Must-haves met:** unlocking uses In-App Purchase only (StoreKit 2); Restore Purchases is on the
  unlock screen; verified transactions only; refunds and revocations re-lock; the IAP is reachable
  by the reviewer at any time (shelf "Unlock" button) and when a session ends.
- **For the App Review notes (Phase 7):** explain the session model, that the IAP can be tested from
  the shelf's Unlock button or by playing 10 minutes, and that sessions repeat without limit.
- **Never gate the 3DS mode** (Phase 10): it is free; `FreePlaySession` only runs for GameCube play.
