# Coverage data providers

Reviewed 2026-10-10. These sources answer different questions; keep each layer labeled separately from recorded measurements.

| Source | Useful for | Decision |
| --- | --- | --- |
| [OpenCellID area search](https://wiki.opencellid.org/docs/api/cells-in-area) | Community cell positions near a chosen map area; LTE and NR filters | Implemented as one manual request for a 1.8 km square, at most 50 cells, with temporary map references. No automatic pagination or inferred serving tower. |
| [OpenCellID exact lookup](https://wiki.opencellid.org/docs/api/cell-position) | A community position for a verified complete cell identity | Retained under Advanced. Gateway node IDs or CID fragments are insufficient to derive the full LTE ECI/5G NCI or PLMN. |
| [Unwired Labs](https://docs.unwiredlabs.com/docs/geolocation/cells) | Device geolocation from supplied LTE/NR observations | Possible future optional device-location source, rather than a physical-tower layer. Validate the full identity and disable fallback when an exact match is needed. Review [terms](https://unwiredlabs.com/tos) and retention permission before saving responses. |
| [Google Geolocation](https://developers.google.com/maps/documentation/geolocation/requests-geolocation) | Device position from cell and Wi-Fi observations, including 5G NCI | Poor fit for the current durable MapKit reference layer: billing and [map display/storage restrictions](https://developers.google.com/maps/documentation/geolocation/policies) require a different integration design. |
| [FCC mobile broadband coverage downloads](https://help.bdc.fcc.gov/hc/en-us/articles/43909220634651-How-to-Download-Mobile-Broadband-Coverage-Data-from-the-FCC-s-National-Broadband-Map-Step-by-Step-Instructions) | Dated carrier-reported modeled coverage polygons | Existing local GeoJSON import is the appropriate separate overlay. A future official download integration should retain dataset date and provider provenance. |

OpenCellID's [access and limits](https://wiki.opencellid.org/docs/getting-started/access-and-limits), [error format](https://wiki.opencellid.org/docs/api/errors) and [attribution requirements](https://wiki.opencellid.org/docs/attribution) control its integration. The UI links OpenCellID and CC BY-SA 4.0 wherever community references are visible. Returned positions may be rounded; they do not establish a physical tower, serving-cell attachment or missing mobile coverage. The request sends the chosen area and key; the provider also sees the connection's network address.

Next useful improvements: an official dated FCC download workflow; import previews with source/age summaries; location accuracy guidance; and provider usage feedback when the API exposes reliable quota metadata. Avoid private carrier website endpoints, guessed full cell IDs and unlabeled interpolation between recorded points.
