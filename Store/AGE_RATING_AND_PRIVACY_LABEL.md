# Age rating questionnaire and App Privacy answers (App Store Connect)

## Age rating
The app ships no games or other content of its own; everything shown is the player's own files.
Suggested answers (owner to confirm in App Store Connect):

| Question | Answer |
|---|---|
| Violence, sexual content, profanity, horror, drugs, gambling, contests | None |
| Unrestricted web access | No (no in-app browser to arbitrary sites) |
| User-generated content / messaging / social | No |
| Simulated gambling, loot boxes | No |
| Medical / wellness | No |

Expected rating: **4+**. Note: Guideline 4.7.5 requires age gating for software *offered by the
app*; Iridia offers none (games come only from the player's own files), so it does not apply. Say so
in the review notes if asked.

## App Privacy ("nutrition label")
- **Data collection: "Data Not Collected"** for every category. No tracking.
- Matches PrivacyInfo.xcprivacy (NSPrivacyTracking false, no collected data types).
- Third-party SDKs: none that collect data (Sentry was removed in Phase 7).

## Export compliance
- Uses only Apple's standard encryption (HTTPS/TLS) → answer **"exempt"** (ITSAppUsesNonExemptEncryption = NO).
