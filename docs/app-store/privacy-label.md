# PicPal — Privacy Nutrition Label

| Data type | Collected? | Linked to identity? | Used for tracking? | Notes |
|-----------|-----------|--------------------|--------------------|-------|
| Camera | Yes | No | No | On-device processing; optional cloud sends still frames only |
| Photos | Yes | No | No | Reference photo picker — selected photo never stored |
| Microphone | No | — | — | AVFoundation declares entitlement; microphone is not used |
| Contact info | No | — | — | |
| Location | No | — | — | |
| Identifiers | No | — | — | |
| Usage data | No | — | — | Telemetry export is local only; not sent to any server |

## Data not linked to you (camera still frames, when cloud tier is enabled by user)

- **Purpose**: App Functionality
- **Retention**: Not stored beyond the current session response
