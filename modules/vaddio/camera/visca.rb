# encoding: ASCII-8BIT

module Vaddio; end
module Vaddio::Camera; end


class Vaddio::Camera::Visca
    include ::Orchestrator::Constants    # these provide optional helper methods
    include ::Orchestrator::Transcoder   # (not used in this module)


    # Discovery Information
    tcp_port 4999 # Need to go through an RS232 gatway
    descriptive_name 'Vaddio PTZ Camera - VISCA protocol'
    generic_name :Camera

    # Communication settings
    tokenize delimiter: "\xFF"
    delay between_sends: 150


    def on_load
        # Constants that are made available to interfaces
        self[:pan_speed_max] = 0x18
        self[:pan_speed_min] = 1
        self[:tilt_speed_max] = 0x14
        self[:tilt_speed_min] = 1

        self[:joy_left] =  -0x14
        self[:joy_right] = 0x14
        self[:joy_center] = 0

        self[:pan_max] = 0x7FBC    # Right
        self[:pan_min] = -32837    # Left

        self[:pan_center] = 0

        self[:tilt_max] = 0x4C2B   # UP
        self[:tilt_min] = -59537   # Down

        self[:tilt_center] = 0

        self[:zoom_max] = 0x6B3
        self[:zoom_min] = 0

        on_update
    end
    
    def on_unload
    end
    
    def on_update
        @presets = setting(:presets) || {}
        self[:presets] = @presets.keys
        self[:invert] = setting(:invert)
    end
    
    def connected
        @polling_timer = schedule.every('60s') do
            logger.debug "-- Polling Vaddio Camera"
            power? do
                if self[:power] == On
                    zoom?
                    pantilt?
                end
            end
        end
    end
    
    def disconnected
        # Disconnected will be called before connect if initial connect fails
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    def power(state)
        target = is_affirmative?(state)

        # Execute command
        if target == On && self[:power] == Off
            send_cmd "\x04\x00\x02", name: :power, delay: 15000
        elsif target == Off && self[:power] == On
            send_cmd "\x04\x00\x03", name: :power, delay: 15000
        end

        # ensure the comman ran successfully
        self[:power_target] = target
        power?
    end

    def power?(options = {}, &block)
        options[:emit] = block if block_given?
        options[:inq] = :power
        send_inq "\x04\x00", options
    end

    def zoom?
        send_inq "\x04\x47", priority: 0, inq: :zoom
    end

    def pantilt?
        send_inq "\x06\x12", priority: 0, inq: :pantilt
    end


    # Absolute position
    def pantilt(pan, tilt)
        pan = to_bin(in_range(pan.to_i, self[:pan_max], self[:pan_min]))
        tilt = to_bin(in_range(tilt.to_i, self[:tilt_max], self[:tilt_min]))

        cmd = [0x06, 0x02, (self[:pan_speed_max] * 0.7).to_i, (self[:tilt_speed_max] * 0.7).to_i].pack('C*')

        # Format the pan tilt value as required
        val = pan.to_s(16).rjust(4, '0')
        val << tilt.to_s(16).rjust(4, '0')
        value = ''
        val.each_char do |char|
            value << '0'
            value << char
        end
        cmd << hex_to_byte(value)

        send_cmd cmd, name: :position
    end

    def joystick(pan_speed, tilt_speed)
        left_max = self[:joy_left]
        right_max = self[:joy_right]

        pan_speed = in_range(pan_speed.to_i, right_max, left_max)
        tilt_speed = in_range(tilt_speed.to_i, right_max, left_max)

        is_centered = false
        if pan_speed == 0 && tilt_speed == 0
            is_centered = true
        end

        options = {}
        options[:name] = :joystick

        cmd = "\x06\x01"

        if is_centered
            options[:priority] = 99
            options[:retries] = 5
            cmd << "\x01\x01\x03\x03"

            # Request the current position once the stop command
            # has run, we are clearing the queue so we use promises to
            # ensure the pantilt command is executed
            send_cmd(cmd, options).then do
                pantilt?
            end
        else
            options[:retries] = 0

            # Calculate direction
            dir_hori = nil
            if pan_speed > 0
                dir_hori = :right
            elsif pan_speed < 0
                dir_hori = :left
            end
            
            dir_vert = nil
            if tilt_speed > 0
                dir_vert = :up
            elsif tilt_speed < 0
                dir_vert = :down
            end

            # Add the absolute speed
            pan_speed = pan_speed * -1 if pan_speed < 0
            tilt_speed = tilt_speed * -1 if tilt_speed < 0
            cmd << pan_speed
            cmd << tilt_speed

            # Provide the direction information
            cmd << __send__("stick_#{dir_vert}#{dir_hori}".to_sym)
            send_cmd cmd, options
        end
    end

    def zoom(position, focus = 0)
        val = in_range(position.to_i, self[:zoom_max], self[:zoom_min])
        
        cmd = "\x04\x47"

        # Format the zoom focus values as required
        val = position.to_s(16).rjust(4, '0')
        val << focus.to_s(16).rjust(4, '0')
        value = ''
        val.each_char do |char|
            value << '0'
            value << char
        end
        cmd << hex_to_byte(value)

        self[:zoom] = position

        send_cmd cmd, name: :zoom
    end

    def adjust_tilt(direction)
        speed = 0
        if direction == 'down'
            speed = self[:invert] ? -0x10 : 0x10
        elsif direction == 'up'
            speed = self[:invert] ? 0x10 : -0x10
        end

        joystick(0, speed)
    end

    def adjust_pan(direction)
        speed = 0
        if direction == 'right'
            speed = 0x10
        elsif direction == 'left'
            speed = -0x10
        end

        joystick(speed, 0)
    end

    # Recall a preset from the database
    def preset(name)
        name_sym = name.to_sym
        values = @presets[name_sym]
        if values
            pantilt(values[:pan], values[:tilt])
            zoom(values[:zoom])
            true
        elsif name_sym == :default
            home
        else
            false
        end
    end

    # Recall a preset from the camera
    def recall_position(number)
        number = in_range(number, 9, 1)
        cmd = "\x04\x3f\x02"
        cmd << number
        send_cmd cmd, name: :recall_position
    end

    def save_position(number)
        number = in_range(number, 9, 1)
        cmd = "\x04\x3f\x01"
        cmd << number
        # No name as we might want to queue this
        send_cmd cmd
    end


    protected


    # Joystick command type
    def stick_up;    "\x03\x01"; end
    def stick_down;  "\x03\x02"; end
    def stick_left;  "\x01\x03"; end
    def stick_right; "\x02\x03"; end
    def stick_upleft;    "\x01\x01"; end
    def stick_upright;   "\x02\x01"; end
    def stick_downleft;  "\x01\x02"; end
    def stick_downright; "\x02\x02"; end


    # We have to use twos compliment for negative numbers
    # to build the binary string
    def to_bin(val)
        if val < 0
            ~(val - 1)
        else
            val
        end
    end

    def from_bin(val)
        if (val & 0b1000000000000000) > 0
            ~(val - 1)
        else
            val
        end
    end


    def send_cmd(cmd, options = {})
        req = "\x88\x01#{cmd}\xff"
        logger.debug { "tell -- 0x#{byte_to_hex(req)} -- #{options[:name]}" }
        send req, options
    end

    def send_inq(inq, options = {})
        req = "\x88\x09#{inq}\xff"
        logger.debug { "ask -- 0x#{byte_to_hex(req)} -- #{options[:inq]}" }
        send req, options
    end


    RespComplete = "\x90\x51".freeze
    RespIgnore = "\x90\x41".freeze
    def received(data, resolve, command)
        logger.debug { "Vaddio sent 0x#{byte_to_hex(data)}" }

        # Process command responses
        if command && command[:inq].nil?
            if data == RespComplete
                return :success
            else
                return :ignore
            end
        end

        # This will probably not ever be true
        return :success unless command && command[:inq]
        return :ignore if data == RespIgnore

        # Process the response
        bytes = str_to_array(data)
        case command[:inq]
        when :power
            self[:power] = bytes[-1] == 2

            if !self[:power_target].nil? && self[:power_target] != self[:power]
                schedule.in 3000 do
                    power(self[:power_target]) if self[:power_target] != self[:power]
                end
            end
        when :zoom
            hex = byte_to_hex(data[2..-1])
            hex_new = "#{hex[1]}#{hex[3]}#{hex[5]}#{hex[7]}"
            self[:zoom] = hex_new.to_i(16)
        when :pantilt
            hex = byte_to_hex(data[2..5])
            pan_hex = "#{hex[1]}#{hex[3]}#{hex[5]}#{hex[7]}"
            self[:pan] = from_bin(pan_hex.to_i(16))

            hex = byte_to_hex(data[6..-1])
            tilt_hex = "#{hex[1]}#{hex[3]}#{hex[5]}#{hex[7]}"
            self[:tilt] = from_bin(tilt_hex.to_i(16))
        end

        :success
    end
end

