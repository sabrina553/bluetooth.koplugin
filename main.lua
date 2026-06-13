--[[--
This is a module to toggle bluetooth for pocketbook inkpad 4

@module koplugin.pocketbook-bluetooth
--]]--


local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

--[[--
---Inkpad has the netagent command, which we will assume is in the path
---"netagent bt" manages the bluetooth connection.
---  commands that work (on my ereader)
---    netagent bt on
---    netagent bt off
---    netagent bt status 
---"netagent net" manages the wifi connection
---  commands that work 
---    netagent net on
---    netagent net off 
--]]--


local PBBT = WidgetContainer:extend{
    name = "PocketBook Bluetooth",
    is_doc_only = false,
}

function PBBT:onPBBTToggle(menu_items) 
    -- netagent bt status
    --  when bt is off, the state is BT_STATE_OFF, 
    --  when on, it may be BT_STATE_ON, BT_STATE_READY, etc
    --  so just check for OFF
    local isoff = os.execute('netagent bt status |grep BT_STATE_OFF')
    local msg=""

    -- if isoff returns 0, then bt is off, and we need to turn it on
    -- execute netagent with & so it doesn't hang the interface.
    -- probably not a good idea to call the toggle really fast
    if isoff == 0 then
        os.execute('netagent bt on &')
        msg='Enabling Bluetooth'
    else 
        -- isoff is not zero, which means we're in one of the "on" states
        -- disable
        os.execute('netagent bt off &')
        msg='Disabling Bluetooth'
    end
    UIManager:show(InfoMessage:new{ text=_(msg),timeout=2, })
end


-- simple force on & off function
function PBBT:onPBBTEnable(menu_items)
    os.execute('netagent bt on &')
    UIManager:show(InfoMessage:new{ text=_("Enabling Bluetooth"), timeout=2, })
end

function PBBT:onPBBTDisable(menu_items)
    os.execute('netagent bt off &')
    UIManager:show(InfoMessage:new{ text=_("Disabling Bluetooth"), timeout=2, })
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
