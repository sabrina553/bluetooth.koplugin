--[[--
This is a debug plugin to test Plugin functionality.

@module koplugin.HelloWorld
--]]--

-- This is a debug plugin, remove the following if block to enable it
--if true then
 --   return { disabled = true, }
--end

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")



local PBBT = WidgetContainer:extend{
    name = "PocketBook Bluetooth",
    is_doc_only = false,
}

function PBBT:onPBBTToggle(menu_items) 
    local isoff = os.execute('netagent bt status |grep BT_STATE_OFF')
    local msg=""
    if isoff == 0 then
	os.execute('netagent bt on &')
	msg='Enabling Bluetooth'
    else 
	os.execute('netagent bt off &')
	msg='Disabling Bluetooth'
    end
    UIManager:show(InfoMessage:new{ text=_(msg),timeout=2, })
end

function PBBT:onPBBTEnable(menu_items)
    os.execute('netagent bt on &')
    UIManager:show(InfoMessage:new{
        text=_("Enabling Bluetooth"),
	timeout=2,
    })
end
function PBBT:onPBBTDisable(menu_items)
    os.execute('netagent bt off &')
    UIManager:show(InfoMessage:new{
        text=_("Disabling Bluetooth"),
	timeout=2,
    })
end



function PBBT:addToMainMenu(menu_items)
    menu_items.pbbt= {
        text= _("PocketBook Bluetooth"),
        sorting_hint = "tools",
        sub_item_table = {
                {
                text = _ ("Enable Bluetooth"),
                callback =
                    function()
                        PBBT:onPBBTEnable()
                    end
                },
                {
                text = _ ("Disable Bluetooth"),
                callback =
                    function()
                        PBBT:onPBBTDisable()
                    end
                },
                {
                text = _ ("Toggle Bluetooth"),
                callback =
                    function()
                        PBBT:onPBBTToggle()
                    end
                },
        }
    }
end

function PBBT:onDispatcherRegisterActions()
        Dispatcher:registerAction("pbbt_toggle", { category="none", event="PBBTToggle", title=_("Bluetooth Tooggle"), general=true,})
        Dispatcher:registerAction("pbbt_enable", { category="none", event="PBBTEnable", title=_("Bluetooth Enable"), general=true,})
        Dispatcher:registerAction("pbbt_disable", { category="none", event="PBBTDisable", title=_("Bluetooth Disable"), general=true,})
end

function PBBT:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

return PBBT
