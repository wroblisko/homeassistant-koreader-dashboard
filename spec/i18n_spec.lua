local i18n = require("homedash_i18n")

describe("homedash_i18n", function()
    describe("lookup", function()
        it("uses the language table first", function()
            assert.are.equal("Odśwież", i18n.lookup("pl", "refresh"))
            assert.are.equal("Refresh", i18n.lookup("en", "refresh"))
        end)

        it("falls back to en when the language lacks the key", function()
            local saved = i18n.STRINGS.pl.refresh
            i18n.STRINGS.pl.refresh = nil
            assert.are.equal("Refresh", i18n.lookup("pl", "refresh"))
            i18n.STRINGS.pl.refresh = saved
        end)

        it("treats an unknown language as en", function()
            assert.are.equal("Close", i18n.lookup("xx", "close"))
            assert.are.equal("Close", i18n.lookup(nil, "close"))
        end)

        it("returns the key itself when nothing knows it", function()
            assert.are.equal("no.such.key", i18n.lookup("pl", "no.such.key"))
            assert.are.equal("no.such.key", i18n.lookup("en", "no.such.key"))
        end)

        it("lets overrides win", function()
            assert.are.equal("Reload", i18n.lookup("en", "refresh", { refresh = "Reload" }))
        end)
    end)

    describe("tables", function()
        it("gives pl every key that en has, and no stray keys", function()
            for key in pairs(i18n.STRINGS.en) do
                assert.is_not_nil(i18n.STRINGS.pl[key], "pl misses " .. key)
            end
            for key in pairs(i18n.STRINGS.pl) do
                assert.is_not_nil(i18n.STRINGS.en[key], "en misses " .. key)
            end
        end)

        it("has a text for every condition code", function()
            for _, code in ipairs(i18n.CONDITION_CODES) do
                for lang in pairs(i18n.STRINGS) do
                    assert.is_not_nil(i18n.STRINGS[lang]["cond." .. code], lang .. " " .. code)
                end
            end
        end)

        it("has seven weekday names and eight compass points per language", function()
            for lang in pairs(i18n.STRINGS) do
                assert.are.equal(7, #i18n.DAYS[lang])
                for i = 1, 8 do
                    assert.is_not_nil(i18n.STRINGS[lang]["compass." .. i])
                end
            end
        end)
    end)

    describe("new", function()
        it("defaults to English with a dot", function()
            local tr = i18n.new(nil)
            assert.are.equal("en", tr.lang)
            assert.are.equal(".", tr.decimal)
            assert.are.equal("Mon", tr.days[2])
            assert.are.equal("Today", tr.t("today"))
        end)

        it("switches to Polish with a comma", function()
            local tr = i18n.new({ lang = "pl" })
            assert.are.equal(",", tr.decimal)
            assert.are.equal("pon.", tr.days[2])
            assert.are.equal("Dziś", tr.t("today"))
        end)

        it("falls back to English for an unknown language", function()
            local tr = i18n.new({ lang = "de" })
            assert.are.equal("en", tr.lang)
            assert.are.equal("Close", tr.t("close"))
        end)

        it("honours decimal, days and strings overrides", function()
            local tr = i18n.new({
                lang = "pl", decimal = ".", days = { "a", "b", "c", "d", "e", "f", "g" },
                strings = { close = "Exit" },
            })
            assert.are.equal(".", tr.decimal)
            assert.are.equal("b", tr.days[2])
            assert.are.equal("Exit", tr.t("close"))
            assert.are.equal("Odśwież", tr.t("refresh"))
        end)

        it("formats placeholders and returns the key for unknown strings", function()
            local tr = i18n.new(nil)
            assert.are.equal("now 12:05", tr.t("now", "12:05"))
            assert.are.equal("every 5 min", tr.t("every_min", 5))
            assert.are.equal("missing.key", tr.t("missing.key"))
            assert.are.equal("missing.key", tr.t("missing.key", 1))
        end)

        it("translates conditions and keeps unknown codes", function()
            assert.are.equal("rain", i18n.new(nil).condition("rainy"))
            assert.are.equal("deszcz", i18n.new({ lang = "pl" }).condition("rainy"))
            assert.are.equal("weird", i18n.new(nil).condition("weird"))
        end)

        it("maps bearings to compass points", function()
            local en, pl = i18n.new(nil), i18n.new({ lang = "pl" })
            assert.are.equal("N", en.compass(359))
            assert.are.equal("E", en.compass(90))
            assert.are.equal("pd.-zach.", pl.compass(225))
            assert.is_nil(en.compass(nil))
        end)
    end)
end)
