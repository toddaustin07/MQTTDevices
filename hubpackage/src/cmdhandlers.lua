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

  MQTT Device Driver - Capability Command handlers

--]]

local log = require "log"
local capabilities = require "st.capabilities"
local cosock = require "cosock"
local socket = require "cosock.socket"          -- just for time


local subs = require "subscriptions"


local function publish_message(device, payload)

  if client and payload then
  
    local qos = tonumber(device.preferences.qos:match('qos(%d)$'))
    assert(client:publish{
      topic = device.preferences.pubtopic,
      payload = payload,
      qos = qos
    })
    log.debug (string.format('Message "%s" published to topic %s with qos=%d', payload, device.preferences.pubtopic, qos))
    
  end

end


local function handle_refresh(driver, device, command)

  log.info ('Refresh requested')

  if device.device_network_id:find('Master', 1, 'plaintext') then
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
        }
        
