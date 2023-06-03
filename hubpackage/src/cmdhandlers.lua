--[[
  Copyright 2022, 2023 Todd Austin

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION

  MQTT Device Driver - Capability Command handlers

--]]

local log = require "log"
local capabilities = require "st.capabilities"
local cosock = require "cosock"
local socket = require "cosock.socket"          -- just for time
local json = require "dkjson"

local subs = require "subscriptions"


local function publish_message(device, payload, opt_topic, opt_qos)

  if client and (client_reset_inprogress==false) and payload then
  
    local pubtopic = opt_topic or device.preferences.pubtopic
    local pubqos = opt_qos or device.preferences.qos:match('qos(%d)$')
    
    assert(client:publish{
      topic = pubtopic,
      payload = payload,
      qos = tonumber(pubqos)
    })
    
    log.debug (string.format('Message "%s" published to topic %s with qos=%d', payload, pubtopic, tonumber(pubqos)))
    
  end

end


local function handle_refresh(driver, device, command)

  log.info ('Refresh requested')

  if device.device_network_id:find('Master', 1, 'plaintext') then
    creator_device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false } }))
    init_mqtt(device)
  else
    subs.mqtt_subscribe(device)
  end

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


local function handle_createdevice(driver, device, command)

  log.debug("Device type selection: ", command.args.value)

  device:emit_event(cap_createdev.deviceType('Creating device...'))

  create_device(driver, command.args.value)

end

local function handle_switch(driver, device, command)

  log.info ('Switch triggered:', command.command)
  
  device:emit_event(capabilities.switch.switch(command.command))

  local dtype = device.device_network_id:match('MQTT_(.+)_+')
  
  if dtype == 'Switch' and device.preferences.publish == true then
      
    local cmdmap = {
                      ['on'] = device.preferences.switchon,
                      ['off'] = device.preferences.switchoff
                   }
           
    publish_message(device, cmdmap[command.command])

  end
end

local function handle_button(driver, device, command)

  log.info ('Button pressed:', command.command)
  
  device:emit_event(capabilities.button.button.pushed({state_change = true}))
  
  if device.preferences.publish == true then
    
    publish_message(device, device.preferences.butpush)
      
  end
end

local function handle_alarm(driver, device, command)

  log.info ('Alarm triggered:', command.command)
  
  device:emit_event(capabilities.alarm.alarm(command.command))

  if device.preferences.publish == true then
    
    local payload
    
    local cmdmap = {
                      ['off'] = device.preferences.alarmoff,
                      ['siren'] = device.preferences.alarmsiren,
                      ['strobe'] = device.preferences.alarmstrobe,
                      ['both'] = device.preferences.alarmboth,
                   }
                   
    publish_message(device, cmdmap[command.command])

  end
end


local function handle_dimmer(driver, device, command)

  log.info ('Dimmmer value changed to ', command.args.level)
  
  local dimmerlevel = command.args.level
  
  if device.preferences.dimmermax then
    if dimmerlevel > device.preferences.dimmermax then
      dimmerlevel = device.preferences.dimmermax
    end
  end
    
  device:emit_event(capabilities.switchLevel.level(dimmerlevel))
  
  if device:supports_capability_by_id('switch') then
    if dimmerlevel > 0 then
      device:emit_event(capabilities.switch.switch('on'))
    else
      device:emit_event(capabilities.switch.switch('off'))
    end
  end
  
  if device.preferences.publish == true then
    
    publish_message(device, tostring(dimmerlevel))
    
  end
end

local function handle_lock(driver, device, command)

  log.info ('Lock command received: ', command.command)
  
  local attrmap = { ['lock']   = 'locked',
                    ['unlock'] = 'unlocked'
                  }
  
  device:emit_event(capabilities.lock.lock(attrmap[command.command]))
  
  if device.preferences.publish == true then
    local cmdmap
    if device.preferences.locklock then
      cmdmap = {
                  ['lock'] = device.preferences.locklock,
                  ['unlock'] = device.preferences.lockunlock
               }
    else
      cmdmap = {
                  ['lock'] = device.preferences.locklocked,
                  ['unlock'] = device.preferences.lockunlocked
               }
    end
                   
    publish_message(device, cmdmap[command.command])
    
  end

end


local function handle_volume(driver, device, command)
  if command.args.volume < device.preferences.threshold then
    device:emit_event(capabilities.soundSensor.sound('not detected'))
  else
    device:emit_event(capabilities.soundSensor.sound('detected'))
  end
end


local function handle_tempset(driver, device, command)

  local tempunit = 'C'
  if device.preferences.dtempunit == 'fahrenheit' then
    tempunit = 'F'
  end
  
  device:emit_event(capabilities.temperatureMeasurement.temperature({value=command.args.temp, unit=tempunit}))
  
  device:emit_event(cap_tempset.vtemp({value=command.args.temp, unit=tempunit}))
  
  if device.preferences.publish == true then
    publish_message(device, tostring(command.args.temp))
  end

end


local function handle_humidityset(driver, device, command)

  device:emit_event(capabilities.relativeHumidityMeasurement.humidity(command.args.humidity))
  
  device:emit_event(cap_humidityset.vhumidity(command.args.humidity))
  
  if device.preferences.publish == true then
    publish_message(device, tostring(command.args.humidity))
  end

end

local function handle_reset(driver, device, command)

  log.info ('Energy Meter Reset requested')
  
  device:emit_event(cap_reset.cmdSelect(' ', { visibility = { displayed = false }}))
  
  device:emit_event(capabilities.energyMeter.energy({value = 0, unit = "kWh" }))
  
end

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

local function handle_custompublish(driver, device, command)

  --disptable(command, '  ', 8)

  log.debug (string.format('%s command Received; topic = %s; msg = %s; qos = %d (%s)', command.command, command.args.topic, command.args.message, command.args.qos, type(command.args.qos)))
  
  publish_message(device, command.args.message, command.args.topic, command.args.qos)

end


local function handle_setenergy(driver, device, command)

  log.info (string.format('Energy value set to %s', command.args.energyval))
  device:emit_event(cap_setenergy.energyval({value = command.args.energyval, unit = device.preferences.eunitsset}))
  device:emit_event(capabilities.energyMeter.energy({value = command.args.energyval, unit=device.preferences.eunitsset}))

  if device.preferences.epublish == true then
    publish_message(device, tostring(command.args.energyval), device.preferences.epubtopic)
  end

end


local function handle_setpower(driver, device, command)

  log.info (string.format('Power value set to %s', command.args.powerval))
  
  local disp_multiplier = 1
  if device.preferences.punitsset == 'mwatts' then
    disp_multiplier = .001
  elseif device.preferences.punitsset == 'kwatts' then
    disp_multiplier = 1000
  end
  device:emit_event(cap_setpower.powerval(command.args.powerval * disp_multiplier))
  device:emit_event(capabilities.powerMeter.power(command.args.powerval * disp_multiplier))

  if device.preferences.ppublish == true then
    publish_message(device, tostring(command.args.powerval), device.preferences.ppubtopic)
  end

end


local function handle_setnumeric(driver, device, command)

  if command.command == 'setNumber' then
    device:emit_event(cap_numfield.numberval(command.args.numberval))
  
    if device.preferences.publish == true then
      
      local sendmsg
      if device.preferences.format == 'json' then
        local msgobj = {}
      
        msgobj[device.preferences.jsonelement] = command.args.numberval
        msgobj[device.preferences.unitkey] = device.state_cache.main[cap_unitfield.ID].unittext.value
        
        sendmsg = json.encode(msgobj, { indent = false })
      
      else
        sendmsg = tostring(command.args.numberval) .. ' ' .. device.state_cache.main[cap_unitfield.ID].unittext.value
      
      end  
      
      publish_message(device, sendmsg)
    end
  
  elseif command.command == 'setUnit' then
    device:emit_event(cap_unitfield.unittext(command.args.unittext))

  end
end

local function handle_shade(driver, device, command)

  local cmdmap =  { 
                    ['open'] = {['attribute'] = 'open', ['pubval'] = device.preferences.shadeopen},
                    ['close'] = {['attribute'] = 'closed', ['pubval'] = device.preferences.shadeclose},
                    ['pause'] = {['attribute'] = 'partially open', ['pubval'] = device.preferences.shadepause},
                    ['setShadeLevel'] = {['attribute'] = command.args.shadeLevel, ['pubval'] = ''},
                  }

  if command.command == 'setShadeLevel' then
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(cmdmap[command.command].attribute))
    cmdmap['setShadeLevel'].pubval = tostring(command.args.shadeLevel)
    if command.args.shadeLevel == 0 then
      device:emit_event(capabilities.windowShade.windowShade('closed'))
    elseif command.args.shadeLevel == 100 then
      device:emit_event(capabilities.windowShade.windowShade('open'))
    else
      device:emit_event(capabilities.windowShade.windowShade('partially open'))
    end
    
  else
    device:emit_event(capabilities.windowShade.windowShade(cmdmap[command.command].attribute))
    if cmdmap[command.command].attribute == 'open' then
      device:emit_event(capabilities.windowShadeLevel.shadeLevel(100))
    elseif cmdmap[command.command].attribute == 'closed' then
      device:emit_event(capabilities.windowShadeLevel.shadeLevel(0))
    end
  end
  
  if device.preferences.publish then
    publish_message(device, cmdmap[command.command].pubval)
  end

end

return  {
          handle_refresh = handle_refresh,
          handle_createdevice = handle_createdevice,
          handle_switch = handle_switch,
          handle_button = handle_button,
          handle_alarm = handle_alarm,
          handle_dimmer = handle_dimmer,
          handle_lock = handle_lock,
          handle_volume = handle_volume,
          handle_tempset = handle_tempset,
          handle_humidityset = handle_humidityset,
          handle_reset = handle_reset,
          handle_custompublish = handle_custompublish,
          handle_setenergy = handle_setenergy,
          handle_setpower = handle_setpower,
          handle_setnumeric = handle_setnumeric,
          handle_shade = handle_shade,
        }
        
