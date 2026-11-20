local _ = require("gettext")

return {
    fullname = _("Home Assistant dashboard"),
    description = _([[Full-screen Home Assistant dashboard for e-ink devices: weather, forecast chart, sensor values and buttons that call Home Assistant services.]]),
    -- Read by scripts/package.sh, the release workflow and plugin updaters
    -- (e.g. updatesmanager.koplugin); keep it equal to the release tag without "v".
    version = "0.1.0",
}
