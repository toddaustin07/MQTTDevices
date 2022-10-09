--[[
  Copyright 2022 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION

  MQTT Device Driver - supports receiving MQTT published messages for recognized device types:  switch, contact, motion, etc.

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"          -- just for time
local log = require "log"
local json = require "dkjson"

local mqtt = require "mqtt"


-- Global variables
thisDriver = {}       -- this is used in the MQTT client module: TODO- pass it in at initialization

-- Module variables

local client = nil
local client_reset_inprogress = false

local initialized = false
local SUBSCRIBED_TOPICS = {}

local creator_device
local clearcreatemsg_timer


-- Custom Capabilities
local cap_createdev = capabilities["partyvoice23922.createmqttdev"]
local cap_status = capabilities["partyvoice23922.status"]
local cap_topiclist = capabilities["partyvoice23922.topiclist"]
local cap_refresh = capabilities["partyvoice23922.refresh"]


local typemeta =  {
                    ['Switch']     = { ['profile'] = 'mqttswitch.v1',        ['created'] = 0, ['switch'] = true },
                    ['Contact']    = { ['profile'] = 'mqttcontact.v1',       ['created'] = 0, ['switch'] = false },
                    ['Motion']     = { ['profile'] = 'mqttmotion.v1',        ['created'] = 0, ['switch'] = false },
                  }

local function disptable(table, tab, maxlevels, currlevel)

	if not currlevel then; currlevel = 0; end
  currlevel = currlevel + 1
  for key, value in pairs(table) do
    if type(key) ~= 'table' then
      log.debug (tab .. '  ' .. key, value)
    else
      log.debug (tab .. '  ', key, value)
    end
    if (type(value) == 'table') and (currlevel < maxlevels) then
      disptable(value, '  ' .. tab, maxlevels, currlevel)
    end
  end
end


local function build_html(list)

  local html_list = ''

  for _, item in ipairs(list) do
    html_list = html_list .. '<tr><td>' .. item .. '</td></tr>\n'
  end

  local html =  {
                  '<!DOCTYPE html>\n',
                  '<HTML>\n',
                  '<HEAD>\n',
                  '<style>\n',
                  'table, td {\n',
                  '  border: 1px solid black;\n',
                  '  border-collapse: collapse;\n',
                  '  font-size: 12px;\n',
                  '  padding: 3px;\n',
                  '}\n',
                  '</style>\n',
                  '</HEAD>\n',
                  '<BODY>\n',
                  '<table>\n',
                  html_list,
                  '</table>\n',
                  '</BODY>\n',
                  '</HTML>\n'
                }
    
  return (table.concat(html))
end


local function create_device(driver, dtype)

  if dtype then

    local PROFILE = typemeta[dtype].profile
    if PROFILE then
    
      local MFG_NAME = 'SmartThings Community'
      local MODEL = 'mqtttdev_' .. dtype
      local LABEL = 'MQTT ' .. dtype
      local ID = 'MQTT_' .. dtype .. '_' .. tostring(socket.gettime())

      log.info (string.format('Creating new device: label=<%s>, id=<%s>', LABEL, ID))
      if clearcreatemsg_timer then
        driver:cancel_timer(clearcreatemsg_timer)
      end

      local create_device_msg = {
                                  type = "LAN",
                                  device_network_id = ID,
                                  label = LABEL,
                                  profile = PROFILE,
                                  manufacturer = MFG_NAME,
                                  model = MODEL,
                                  vendor_provided_label = LABEL,
                                }

      assert (driver:try_create_device(create_device_msg), "failed to create device")
    end
  end
end

local function get_element_value(inputjson, key)

  local compound = inputjson
  local found = true

  for element in string.gmatch(key, "[^%.]+") do
    compound = compound[element]
    if compound == nil then
      found = false
      break
    end
  end

  if found then
    return compound
  else
    return
  end

end


local function determine_devices(received_topic)

  local targetlist = {}
  local devicelist = thisDriver:get_devices()

  for id, topic in pairs(SUBSCRIBED_TOPICS) do

    if topic == received_topic then

      for _, device in ipairs(devicelist) do

        if device.device_network_id == id then

          table.insert(targetlist, device)

        end
      end
    end
  end

  return targetlist

end

local function process_message(topic, msg)

  log.debug (string.format("Processing received data msg: %s", msg))
  log.debug (string.format("\tFrom topic: %s", topic))

  local devicelist = determine_devices(topic)
  log.debug ('# device matches:', #devicelist)

  if #devicelist > 0 then

    for _, device in ipairs(devicelist) do

      local value

      if device.preferences.format == 'json' then
        local msgjson, _, err = json.decode (msg, 1, nil)
        if err then
          log.error ("JSON decode error processing received message:", err)
        end

        if msgjson then
          value = get_element_value(msgjson, device.preferences.jsonelement)
          if type(value) == 'number' then
            log.debug ('Msg Value is a number')
            value = tostring(value)
          end
        else
          log.error ("No JSON found in received message")
        end

      elseif device.preferences.format == 'string' then
        value = msg
      end

      if value then
        local dtype = device.device_network_id:match('MQTT_(.+)_+')

        if dtype == 'Switch' then
          if value == device.preferences.switchon then
            device:emit_event(capabilities.switch.switch.on())
          elseif value == device.preferences.switchoff then
            device:emit_event(capabilities.switch.switch.off())
          else
            log.warn ('Unconfigured switch value received')
          end
        elseif dtype == 'Contact' then
          if value == device.preferences.contactopen then
            device:emit_event(capabilities.contactSensor.contact.open())
          elseif value == device.preferences.contactclosed then
            device:emit_event(capabilities.contactSensor.contact.closed())
          else
            log.warn ('Unconfigured contact value received')
          end
        elseif dtype == 'Motion' then
          if value == device.preferences.motionactive then
            device:emit_event(capabilities.motionSensor.motion.active())
          elseif value == device.preferences.motioninactive then
            device:emit_event(capabilities.motionSensor.motion.inactive())
          else
            log.warn ('Unconfigured motion value received')
          end
        end
      end
    end
  end
end


local function create_MQTT_client(device)

  local connect_args = {}
  connect_args.uri = device.preferences.broker
  connect_args.clean = true
  
  if device.preferences.userid ~= '' and device.preferences.password ~= '' then
    if device.preferences.userid ~= 'xxxxx' and device.preferences.password ~= 'xxxxx' then
      connect_args.username = device.preferences.userid
      connect_args.password = device.preferences.password
    end
  end

  -- create mqtt client
  client = mqtt.client(connect_args)

  client:on{
    connect = function(connack)
      if connack.rc ~= 0 then
        log.error ("connection to broker failed:", connack:reason_string(), connack)
        device:emit_event(cap_status.status('Failed to Connect to Broker'))
        return
      end
      log.info("Connected to MQTT broker:", connack) -- successful connection
      device:emit_event(cap_status.status('Connected to Broker'))
    end,

    message = function(msg)
      assert(client:acknowledge(msg))

      --log.info("received:", msg, type(msg))
      -- example msg:  PUBLISH{payload="Hello world", topic="testmqtt/pimylifeup", dup=false, type=3, qos=0, retain=false}

      process_message(msg.topic, msg.payload)


    end,

    error = function(err)
      log.error("MQTT client error:", err)
    end,
  }

  return client

end

local function is_subscribed(qtopic)

  for _, topic in pairs(SUBSCRIBED_TOPICS) do
    if topic == qtopic then; return true; end
  end
  return false

end

local function unique_topic_list()

  local list = {}
  for _, topic in pairs(SUBSCRIBED_TOPICS) do
    local alreadyfound=false
    for _, item in ipairs(list) do
      if item == topic then; alreadyfound = true; end
    end
    if not alreadyfound then
      table.insert(list, topic)
    end
  end
  return list

end

local function subscribe_topic(device)

  if is_subscribed(device.preferences.subTopic) then
    log.debug ('Already subscribed to topic', device.preferences.subTopic)
    SUBSCRIBED_TOPICS[device.device_network_id] = device.preferences.subTopic
    device:emit_event(cap_status.status('Subscribed'))
  else
    SUBSCRIBED_TOPICS[device.device_network_id] = device.preferences.subTopic
    assert(client:subscribe{ topic=device.preferences.subTopic, qos=1, callback=function(suback)
      log.info(string.format("Device <%s> subscribed to %s: %s", device.label, device.preferences.subTopic, suback))
      
      creator_device:emit_event(cap_topiclist.topiclist(build_html(unique_topic_list())))
      device:emit_event(cap_status.status('Subscribed'))

    end})
  end

end


local function subscribe_all()

  local devicelist = thisDriver:get_devices()
  for _, device in ipairs(devicelist) do
    if not device.device_network_id:find('Master', 1, 'plaintext') then
      if (device.preferences.subTopic ~= 'xxxxx/xxxxx') and (device.preferences.subTopic ~= nil) then
        subscribe_topic(device)
      end
    end
  end
end

local function unsubscribe(id, topic)

  local rc, err = client:unsubscribe{ topic=topic, callback=function(unsuback)
        log.info("\t\tUnsubscribe callback:", unsuback)
    end}
    
  if rc == false then
    log.debug ('\tUnsubscribe failed with err:', err)
  else
    log.debug (string.format('\tUnsubscribed from %s', topic))
    SUBSCRIBED_TOPICS[id] = nil
  end

end

local function unsubscribe_all()

  local sublist = SUBSCRIBED_TOPICS

  for id, topic in pairs(sublist) do
    unsubscribe(id, topic)
  end

end

local function schedule_subscribe()

  if client then
    subscribe_all()
  else
    log.warn('Broker not yet connected')
    thisDriver:call_with_delay(2, schedule_subscribe)
  end
end


local function init_mqtt(device)

  if device.preferences.broker == '192.168.1.xxx' or
     device.preferences.subTopic == 'xxxxx/xxxxx' then

      log.warn ('Device settings not initialized')
      return
  end

  device:emit_event(cap_status.status('Reconnecting'))
  if client then
    log.debug ('Unsubscribing all and disconnecting current client...')
    
    unsubscribe_all()

    local rc, err = client:disconnect()
    if rc == false then
      log.debug ('\tDisconnect failed with err:', err)
    elseif rc == true then
      log.debug ('\tDisconnected')
    end
  end

  client = create_MQTT_client(device)

  -- Run MQTT loop in separate thread; TODO: thread needs to somehow get killed if manual reconnect (?)

  cosock.spawn(function()
    while true do
      local ok, err = mqtt.run_sync(client)

      if ok == false then
        if string.lower(err):find('connection refused', 1, 'plaintext') or err == "closed" then
          if client_reset_inprogress == true then; break; end
          device:emit_event(cap_status.status('Connection Lost; Reconnecting'))
          repeat
            -- create new mqtt client
            cosock.socket.sleep(15)
            if client_reset_inprogress == true then
              client_reset_inprogress = false
              return
            end
            log.info ('Attempting to reconnect to broker...')
            client = create_MQTT_client(device)
          until client

        else
          break
        end
      else
        log.error ('Unexpected return from MQTT client:', ok, err)
      end
    end
  end, 'MQTT synch mode')

  -- Schedule device subscriptions
  thisDriver:call_with_delay(5, schedule_subscribe)

end


local function get_subscribed_topic(device)

  for id, topic in pairs(SUBSCRIBED_TOPICS) do
    if id == device.device_network_id then
      return id, topic
    end
  end
end


local function mqtt_subscribe(device)

  if client then

    local id, topic = get_subscribed_topic(device)

    if topic then
      log.debug (string.format('Unsubscribing device <%s> from %s', device.label, topic))
      unsubscribe(id, topic)
    end

    subscribe_topic(device)
  end
end

-----------------------------------------------------------------------
--                          COMMAND HANDLERS
-----------------------------------------------------------------------

local function handle_refresh(driver, device, command)

  log.info ('Refresh requested')

  if device.device_network_id:find('Master', 1, 'plaintext') then
    client_reset_inprogress = true
    init_mqtt(device)
  else
    mqtt_subscribe(device)
  end

end

local function handle_createdevice(driver, device, command)

  log.debug("Device type selection: ", command.args.value)

  device:emit_event(cap_createdev.deviceType('Creating device...'))

  create_device(driver, command.args.value)

end

local function handle_switch(driver, device, command)

  log.info ('Switch triggered:', command.command)
  
  device:emit_event(capabilities.switch.switch(command.command))

  if device.preferences.publish == true then
    if client then
    
      local payload
      if command.command == 'on' then
        payload = device.preferences.switchon
      elseif command.command == 'off' then
        payload = device.preferences.switchoff
      end

      if payload then
        local qos = tonumber(device.preferences.qos:match('qos(%d)$'))
        assert(client:publish{
					topic = device.preferences.pubtopic,
					payload = payload,
					qos = qos
				})
        log.debug (string.format('Message "%s" published to topic %s with qos=%d', device.preferences.pubtopic, payload, qos))
      
      end
    end
  end
end
      
------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)

  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  
  if device.device_network_id:find('Master', 1, 'plaintext') then
  
    device:try_update_metadata({profile='mqttcreator.v1'})              -- *** REMOVE IN NEXT UPDATE ***
    creator_device = device
    device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false } }))
    device:emit_event(cap_status.status('Not Connected'))
    device:emit_event(cap_topiclist.topiclist(' '))
    
    initialized = true
    init_mqtt(device)

  else
    local dtype = device.device_network_id:match('MQTT_(.+)_+')       
    if dtype == 'Switch' then
      device:try_update_metadata({profile='mqttswitch.v1'})             -- *** REMOVE IN NEXT UPDATE ***
    elseif dtype == 'Contact' then
      device:try_update_metadata({profile='mqttcontact.v1'})            -- *** REMOVE IN NEXT UPDATE ***
    elseif dtype == 'Motion' then
      device:try_update_metadata({profile='mqttmotion.v1'})             -- *** REMOVE IN NEXT UPDATE ***
    end
    device:emit_event(cap_status.status('Not Subscribed'))
  end
  
end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")

  if not device.device_network_id:find('Master', 1, 'plaintext') then

    local dtype = device.device_network_id:match('MQTT_(.+)_+')

    if dtype == 'Switch' then
      device:emit_event(capabilities.switch.switch('off'))
    elseif dtype == 'Contact' then
      device:emit_event(capabilities.contactSensor.contact('closed'))
    elseif dtype == 'Motion' then
      device:emit_event(capabilities.motionSensor.motion('inactive'))
    end

    creator_device:emit_event(cap_createdev.deviceType('Device created'))
    clearcreatemsg_timer = driver:call_with_delay(10, function()
        clearcreatemsg_timer = nil
        creator_device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false }}))
      end
    )

  end
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  log.info ('Device doConfigure lifecycle invoked')

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)

  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")

  if not device.device_network_id:find('Master', 1, 'plaintext') then
    local id, topic = get_subscribed_topic(device)

    if topic then
      unsubscribe(id, topic)
    end
  else
    initialized = false
  end

  local devicelist = driver:get_devices()

  if #devicelist == 0 then
    if client then
      client:disconnect()
    end
  end

end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end


local function shutdown_handler(driver, event)

  log.info ('*** Driver being shut down ***')

  if client then

    for _, topic in ipairs(SUBSCRIBED_TOPICS) do
      client:unsubscribe{ topic, callback=function(unsuback)
        log.info("\tUnsubscribed from " .. topic)
      end}
    end

    client_reset_inprogress = true
    client:disconnect()
    creator_device:emit_event(cap_status.status('Driver Shutdown'))
    log.info("\tDisconnected from MQTT broker")
  end

end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

  -- Did preferences change?
  if args.old_st_store.preferences then

    local reset_connection = false
    local ip_changed = false
    local uname_changed = false
    local pw_changed = false

    if args.old_st_store.preferences.subTopic ~= device.preferences.subTopic then
      log.info ('Subscribe Topic changed to: ', device.preferences.subTopic)
      subscribe_topic(device)
    elseif args.old_st_store.preferences.userid ~= device.preferences.userid then
      uname_changed = true
    elseif args.old_st_store.preferences.password ~= device.preferences.password then
      pw_changed = true
    elseif args.old_st_store.preferences.broker ~= device.preferences.broker then
      log.info ('Broker URI changed to: ', device.preferences.broker)
      ip_changed = true
    end
    
    if ip_changed or uname_changed or pw_changed then
      if device.preferences.broker ~= '192.168.1.xxx' then
        client_reset_inprogress = true
        init_mqtt(device)
      end
    end

  end
end


-- Create Primary Creator Device
local function discovery_handler(driver, _, should_continue)

  if not initialized then

    log.info("Creating MQTT Creator device")

    local MFG_NAME = 'SmartThings Community'
    local MODEL = 'MQTTCreatorV1'
    local VEND_LABEL = 'MQTT Device Creator V1' --update; change for testing
    local ID = 'MQTTDev_Masterv1'               --change for testing
    local PROFILE = 'mqttcreator.v1'            --update; change for testing

    -- Create master creator device

    local create_device_msg = {
                                type = "LAN",
                                device_network_id = ID,
                                label = VEND_LABEL,
                                profile = PROFILE,
                                manufacturer = MFG_NAME,
                                model = MODEL,
                                vendor_provided_label = VEND_LABEL,
                              }

    assert (driver:try_create_device(create_device_msg), "failed to create creator device")

    log.debug("Exiting device creation")

  else
    log.info ('MQTT Creator device already created')
  end
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("MQTT Devices", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  capability_handlers = {
    [cap_createdev.ID] = {
      [cap_createdev.commands.setDeviceType.NAME] = handle_createdevice,
    },
    [cap_refresh.ID] = {
      [cap_refresh.commands.push.NAME] = handle_refresh,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch,
      [capabilities.switch.commands.off.NAME] = handle_switch,
    },
  }
})

log.info ('MQTT Device Driver V1 Started!!!')

thisDriver:run()
