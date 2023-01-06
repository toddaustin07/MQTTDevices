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

  MQTT Device Driver - handles all MQTT message received for each device type

--]]

local log = require "log"
local capabilities = require "st.capabilities"
local json = require "dkjson"
local stutils = require "st.utils"

local sub = require "subscriptions"


local function is_array(t)
  if type(t) ~= "table" then return false end
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then return false end
  end
  return true
end


local function getJSONElement(key, jsonstring)

  if not key or type(key) ~= 'string' then
    log.error ('Invalid JSON key string')
    return
  end

  local compound, pos, err = json.decode (jsonstring, 1, nil)

  if not compound then
    if err then
      log.error (string.format('JSON decode error: %s', err))
    end
    return
  end

  local found = false
  local elementslist = {}

  for element in string.gmatch(key, "[^%.]+") do
    table.insert(elementslist, element)
  end
  
  for el_idx=1, #elementslist do
    jsonelement = elementslist[el_idx]
    local key = jsonelement:match('^([^%[]+)')
    local array_index = jsonelement:match('%[(%d+)%]$')
    if array_index then; array_index = tonumber(array_index) + 1; end	-- adjust for Lua indexes starting at 1
    compound = compound[key]
    if compound == nil then; break; end
    
    if array_index then
      if is_array(compound) then
        if compound[array_index] then
          compound = compound[array_index]
        else
          break
        end
      else
        break
      end
    end
    
    if type(compound) ~= 'table' then
      if el_idx == #elementslist then; found = true; end
    end
  end
  
  if found then
    return compound
  end
end


local function motionplus(device, msg)

  local lightvalue = getJSONElement(device.preferences.lightkey, msg)
  if type(lightvalue) == 'number' then
    device:emit_event(capabilities.illuminanceMeasurement.illuminance(lightvalue))
  end
  
  local batteryvalue = getJSONElement(device.preferences.batterykey, msg)
  if type(batteryvalue) == 'number' then
    device:emit_event(capabilities.battery.battery(batteryvalue))
  end

end


local function process_message(topic, msg)

  log.debug (string.format("Processing received data msg: %s", msg))
  log.debug (string.format("\tFrom topic: %s", topic))

  local devicelist = sub.determine_devices(topic)
  log.debug ('# device matches for topic:', #devicelist)

  if #devicelist > 0 then

    for _, device in ipairs(devicelist) do

      log.debug ('Match for', device.label)
      local value
      local dtype = device.device_network_id:match('MQTT_(.+)_+')

      if (device.preferences.format == 'json') or (device.preferences.format == nil) then
      
        value = getJSONElement(device.preferences.jsonelement, msg)
      
        if value ~= nil then; value = tostring(value); end

      elseif device.preferences.format == 'string' then
        value = msg
      end

      if value ~= nil then
        
        if (dtype == 'Motion') or (dtype == 'MotionPlus') then
          if value == device.preferences.motionactive then
            device:emit_event(capabilities.motionSensor.motion.active())
          elseif value == device.preferences.motioninactive then
            device:emit_event(capabilities.motionSensor.motion.inactive())
          else
            log.warn ('Unconfigured motion value received')
          end
        end

        if dtype == 'MotionPlus' then
        
          motionplus(device, msg)

        elseif dtype == 'Switch' then
          if value == device.preferences.switchon then
            device:emit_event(capabilities.switch.switch.on())
          elseif value == device.preferences.switchoff then
            device:emit_event(capabilities.switch.switch.off())
          else
            log.warn ('Unconfigured switch value received')
          end
          
        elseif dtype == 'Button' then  
          if value == device.preferences.butpush then
            device:emit_event(capabilities.button.button.pushed({state_change = true}))
          elseif value == device.preferences.butheld then
            device:emit_event(capabilities.button.button.held({state_change = true}))
          elseif value == device.preferences.butdouble then
            device:emit_event(capabilities.button.button.double({state_change = true}))
          elseif value == device.preferences.but3x then
            device:emit_event(capabilities.button.button.pushed_3x({state_change = true}))
          else
            log.warn ('Unconfigured button value received')
          end
            
        elseif dtype == 'Contact' then
          if value == device.preferences.contactopen then
            device:emit_event(capabilities.contactSensor.contact.open())
          elseif value == device.preferences.contactclosed then
            device:emit_event(capabilities.contactSensor.contact.closed())
          else
            log.warn ('Unconfigured contact value received')
          end
          
        elseif dtype == 'Alarm' then
          if value == device.preferences.alarmoff then
            device:emit_event(capabilities.alarm.alarm.off())
          elseif value == device.preferences.alarmsiren then
            device:emit_event(capabilities.alarm.alarm.siren())
          elseif value == device.preferences.alarmstrobe then
            device:emit_event(capabilities.alarm.alarm.strobe())
          elseif value == device.preferences.alarmboth then
            device:emit_event(capabilities.alarm.alarm.both())
          else
            log.warn ('Unconfigured alarm value received')
          end
          
        elseif dtype == 'Dimmer' then
          local numvalue = tonumber(value)
          if numvalue then
            log.debug ('Dimmer value received:', numvalue)
            if numvalue < 0 then; numvalue = 0; end
            if numvalue > 100 then; numvalue = 100; end
            
            if device.preferences.dimmermax then
              if numvalue > device.preferences.dimmermax then
                numvalue = device.preferences.dimmermax
              end
            end
            
            device:emit_event(capabilities.switchLevel.level(numvalue))
            
            if device:supports_capability_by_id('switch') then
              if numvalue > 0 then
                device:emit_event(capabilities.switch.switch('on'))
              else
                device:emit_event(capabilities.switch.switch('off'))
              end
            end
            
          else
            log.warn('Invalid dimmer value received (NaN)');
          end
          
        elseif dtype == 'Acceleration' then  
          if value == device.preferences.accelactive then
            device:emit_event(capabilities.accelerationSensor.acceleration.active())
          elseif value == device.preferences.accelinactive then
            device:emit_event(capabilities.accelerationSensor.acceleration.inactive())
          else
            log.warn ('Unconfigured acceleration value received')
          end
          
        elseif dtype == 'Lock' then  
          if value == device.preferences.locklocked then
            device:emit_event(capabilities.lock.lock('locked'))
          elseif value == device.preferences.lockunlocked then
            device:emit_event(capabilities.lock.lock('unlocked'))
          else
            log.warn ('Unconfigured lock value received')
          end
          
        elseif dtype == 'Presence' then  
          if value == device.preferences.presencepresent then
            device:emit_event(capabilities.presenceSensor.presence('present'))
          elseif value == device.preferences.presencenotpresent then
            device:emit_event(capabilities.presenceSensor.presence('not present'))
          else
            log.warn ('Unconfigured presence value received')
          end
          
        elseif dtype == 'Sound' then  
          local numvalue = tonumber(value)
          if numvalue then
            log.debug ('Sound value received:', numvalue)
            if numvalue < 0 then; numvalue = 0; end
            if numvalue > 100 then; numvalue = 100; end
            device:emit_event(capabilities.audioVolume.volume(numvalue))
            if numvalue >= device.preferences.threshold then
              device:emit_event(capabilities.soundSensor.sound('detected'))
            else
              device:emit_event(capabilities.soundSensor.sound('not detected'))
            end
          else
            log.warn('Invalid sound value received (NaN)');
          end
         
        elseif dtype == 'Water' then  
          if value == device.preferences.waterwet then
            device:emit_event(capabilities.waterSensor.water.wet())
          elseif value == device.preferences.waterdry then
            device:emit_event(capabilities.waterSensor.water.dry())
          else
            log.warn ('Unconfigured water value received')
          end
          
        elseif dtype == 'Temperature' then
        
          local tempunit = 'C'
          if device.preferences.dtempunit == 'fahrenheit' then
            tempunit = 'F'
          end
          
          value = tonumber(value)
          local tempvalue = value
          if device.preferences.rtempunit == 'fahrenheit' then
            if device.preferences.dtempunit == 'celsius' then
              tempvalue = stutils.f_to_c(value)
            end
          elseif device.preferences.dtempunit == 'fahrenheit' then
              tempvalue = stutils.c_to_f(value)
          end
          
          device:emit_event(capabilities.temperatureMeasurement.temperature({value = tempvalue, unit = tempunit}))
          device:emit_event(cap_tempset.vtemp({value = tempvalue, unit = tempunit}))
          
        elseif dtype == 'Humidity' then
          value = tonumber(value)
          if type(value) == 'number' then
            device:emit_event(capabilities.relativeHumidityMeasurement.humidity(value))
            device:emit_event(cap_humidityset.vhumidity(value))
          end
          
        elseif dtype == 'Energy' then
          device:emit_event(capabilities.energyMeter.energy({value = tonumber(value), unit = device.preferences.units }))
          
        elseif dtype == 'Text' then
          device:emit_event(cap_text.text(value))
          
        end
        
      elseif dtype == 'MotionPlus' then
        motionplus(device, msg)
      else
        log.warn ('No valid value found in message; ignoring')
      end
    end
  end
end

return	{
					process_message = process_message
				}
