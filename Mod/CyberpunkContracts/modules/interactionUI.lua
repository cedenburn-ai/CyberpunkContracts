-- Minimal InteractionUI - extracted from keanuWheeze's library
-- No external dependencies. Drop in modules/ folder.

local ui = {
    baseControler = nil,
    hub = nil,
    callbacks = {},
    hubShown = false,
    selectedIndex = 0,
    input = false
}

function ui.createChoice(localizedName, icon, choiceType)
    local choice = gameinteractionsvisListChoiceData.new()
    choice.localizedName = localizedName or "Choice"
    choice.inputActionName = CName("None")
    if icon then
        local part = gameinteractionsChoiceCaption.new()
        part:AddPartFromRecord(icon)
        choice.captionParts = part
    end
    if choiceType then
        local choiceT = gameinteractionsChoiceTypeWrapper.new()
        choiceT:SetType(choiceType)
        choice.type = choiceT
    end
    return choice
end

function ui.createHub(title, choices, activityState)
    local hub = gameinteractionsvisListChoiceHubData.new()
    hub.title = title or "Title"
    hub.choices = choices or {}
    hub.activityState = activityState or gameinteractionsvisEVisualizerActivityState.Active
    hub.hubPriority = 1
    hub.id = 69420 + math.random(99999)
    return hub
end

function ui.setHub(hub)
    ui.hub = hub
end

function ui.showHub()
    if not ui.hub or not ui.baseControler then
        print("[InfiniteReplay] InteractionUI: No controller yet. Walk near any interactable first.")
        return
    end
    print("[InfiniteReplay] InteractionUI: Showing hub...")
    local ok, err = pcall(function()
        local data = DialogChoiceHubs.new()
        data.choiceHubs = {ui.hub}
        ui.baseControler.AreDialogsOpen = true
        ui.baseControler.dialogIsScrollable = #ui.hub.choices > 1
        ui.baseControler:OnDialogsSelectIndex(0)
        ui.baseControler:UpdateDialogsData(data)
        ui.baseControler:OnInteractionsChanged()
        ui.baseControler:UpdateListBlackboard()
        ui.baseControler:OnDialogsActivateHub(ui.hub.id)
        ui.hubShown = true
        ui.selectedIndex = 0
    end)
    if not ok then
        print("[InfiniteReplay] InteractionUI: showHub error - " .. tostring(err))
    end
end

function ui.hideHub()
    if not ui.hub or not ui.baseControler then return end
    local data = DialogChoiceHubs.new()
    ui.baseControler:UpdateDialogsData(data)
    ui.baseControler:OnInteractionsChanged()
    ui.baseControler:UpdateListBlackboard()
    ui.hubShown = false
end

function ui.registerChoiceCallback(choiceIndex, callback)
    ui.callbacks[choiceIndex] = callback
end

function ui.clearCallbacks()
    ui.callbacks = {}
end

function ui.update()
    if ui.hubShown then
        pcall(function()
            Game.GetBlackboardSystem():Get(GetAllBlackboardDefs().UIInteractions):SetInt(GetAllBlackboardDefs().UIInteractions.SelectedIndex, ui.selectedIndex, true)
        end)
    end
    ui.input = false
end

function ui.init()
    -- Hook OnDialogsData - fires whenever player approaches any interactable in the world
    -- This captures the controller reference reliably since OnInitialize fires before mods load
    ObserveAfter("InteractionUIBase", "OnDialogsData", function(this, value)
        if not ui.baseControler then
            ui.baseControler = this
            print("[InfiniteReplay] InteractionUI: Controller captured via OnDialogsData!")
        end
    end)
    
    ObserveAfter("InteractionUIBase", "OnInitialize", function(this)
        ui.baseControler = this
        print("[InfiniteReplay] InteractionUI: Controller captured via OnInitialize!")
    end)
    
    Observe("InteractionUIBase", "OnDialogsSelectIndex", function(this, idx)
        if ui.hubShown then
            ui.selectedIndex = idx
        end
    end)
    
    print("[InfiniteReplay] InteractionUI: Hooks registered. Walk near any interactable to capture controller.")
end

return ui