local _ = require("gettext")

return {
    fullname = _("Home Assistant dashboard"),
    description = _([[Full-screen Home Assistant dashboard for e-ink devices: weather, forecast chart, sensor values and buttons that call Home Assistant services.]]),
    -- KOReader ignores this field; scripts/package.sh reads it for the zip name.
    version = "0.1.0",
}
