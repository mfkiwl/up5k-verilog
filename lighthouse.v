/** \file
 * Print the lengths of timer pulses from the lighthouse sensors.
 */
`include "util.v"
`include "uart.v"

module top(
	output led_r,
	output led_g,
	output led_b,
	output serial_txd,
	input serial_rxd,
	output spi_cs,
	output debug0,
	input gpio_18,
	input gpio_28,
	input gpio_38
);
	assign spi_cs = 1; // it is necessary to turn off the SPI flash chip

	// map the sensor
	wire lighthouse_a = gpio_28;

	wire clk_48;
	wire reset = 0;
	SB_HFOSC u_hfosc (
		.CLKHFPU(1'b1),
		.CLKHFEN(1'b1),
		.CLKHF(clk_48)
	);

	// pulse the green LED to know that we're alive
	reg [31:0] counter;
	always @(posedge clk_48)
		counter <= counter + 1;
	wire pwm_g;
	pwm pwm_g_driver(clk_48, 1, pwm_g);
	assign led_g = !(counter[25:23] == 0 && pwm_g);

	assign led_b = serial_rxd; // idles high

	// generate a 3 MHz/12 MHz serial clock from the 48 MHz clock
	// this is the 3 Mb/s maximum supported by the FTDI chip
	wire clk_1, clk_4;
	divide_by_n #(.N(16)) div1(clk_48, reset, clk_1);
	divide_by_n #(.N( 4)) div4(clk_48, reset, clk_4);

	wire [7:0] uart_rxd;
	wire uart_rxd_strobe;

	uart_rx rxd(
		.mclk(clk_48),
		.reset(reset),
		.baud_x4(clk_4),
		.serial(serial_rxd),
		.data(uart_rxd),
		.data_strobe(uart_rxd_strobe)
	);

	assign debug0 = serial_txd;
	assign led_r = serial_txd;

	reg [7:0] uart_txd;
	reg uart_txd_strobe = 0;

	uart_tx_fifo txd(
		.clk(clk_48),
		.reset(reset),
		.baud_x1(clk_1),
		.serial(serial_txd),
		.data(uart_txd),
		.data_strobe(uart_txd_strobe)
	);

	// output buffer
	parameter FIFO_WIDTH = 80;
	reg [FIFO_WIDTH-1:0] timer_fifo_write;
	reg timer_fifo_write_strobe;
	wire timer_fifo_available;
	wire [FIFO_WIDTH-1:0] timer_fifo_read;
	reg timer_fifo_read_strobe;

	fifo #(.WIDTH(FIFO_WIDTH),.NUM(16)) timer_fifo(
		.clk(clk_48),
		.reset(reset),
		.data_available(timer_fifo_available),
		.write_data(timer_fifo_write),
		.write_strobe(timer_fifo_write_strobe),
		.read_data(timer_fifo_read),
		.read_strobe(timer_fifo_read_strobe)
	);

	wire [23:0] angle_a0;
	wire [23:0] angle_a1;
	wire [23:0] angle_a2;
	wire [23:0] angle_a3;
	wire [3:0] sweep_strobe_a;

	lighthouse_sensor sensor_a(
		.clk(clk_48),
		.reset(reset),
		.raw_pin(lighthouse_a),
		.angle0(angle_a0),
		.angle1(angle_a1),
		.angle2(angle_a2),
		.angle3(angle_a3),
		.strobe(sweep_strobe_a)
	);

	always @(posedge clk_48)
	begin
		timer_fifo_write_strobe <= 0;

		if (sweep_strobe_a != 0)
		begin
			timer_fifo_write <= {
				angle_a0[19:0],
				angle_a1[19:0],
				angle_a2[19:0],
				angle_a3[19:0]
			};
			timer_fifo_write_strobe <= 1;
		end
	end

	reg [FIFO_WIDTH-1:0] out;
	reg [5:0] out_bytes;

	always @(posedge clk_48)
	begin
		uart_txd_strobe <= 0;
		timer_fifo_read_strobe <= 0;

		// convert timer deltas to hex digits
		if (out_bytes != 0)
		begin
			uart_txd_strobe <= 1;
			out_bytes <= out_bytes - 1;
			if (out_bytes == 1)
				uart_txd <= "\r";
			else
			if (out_bytes == 2)
				uart_txd <= "\n";
			else
			if (out_bytes == 3+5 || out_bytes == 3+11 || out_bytes == 3+17)
				uart_txd <= " ";
			else begin
				uart_txd <= hexdigit(out[FIFO_WIDTH-1:FIFO_WIDTH-4]);
				out <= { out[FIFO_WIDTH-5:0], 4'b0 };
			end

		end else
		if (timer_fifo_available)
		begin
			out <= timer_fifo_read;
			timer_fifo_read_strobe <= 1;
			out_bytes <= 2 + 3 + FIFO_WIDTH/4;
		end
	end

endmodule


module lighthouse_sensor(
	input clk,
	input reset,
	input raw_pin,
	output reg [23:0] angle0,
	output reg [23:0] angle1,
	output reg [23:0] angle2,
	output reg [23:0] angle3,
	output ootx_bit,
	output [3:0] strobe
);
	parameter WIDTH = 24;
	parameter MHZ = 48;

	wire sweep_strobe;
	wire [WIDTH-1:0] sync0;
	wire [WIDTH-1:0] sync1;
	wire [24-1:0] sweep;

	lighthouse_sweep #(
		.WIDTH(WIDTH),
		.CLOCKS_PER_MICROSECOND(MHZ)
	) lh_sweep(
		.clk(clk),
		.reset(reset),
		.raw_pin(raw_pin),
		.sync0(sync0),
		.sync1(sync1),
		.sweep(sweep),
		.sweep_strobe(sweep_strobe)
	);

	wire skip0, data0, axis0, valid0;
	wire skip1, data1, axis1, valid1;

	lighthouse_sync_decode #(.MHZ(MHZ)) sync0_decode(
		sync0, skip0, data0, axis0, valid0);

	lighthouse_sync_decode #(.MHZ(MHZ)) sync1_decode(
		sync1, skip1, data1, axis1, valid1);


	always @(posedge clk)
	begin
		strobe <= 0;

		if (reset)
		begin
			// nothing to do
		end else
		if (sweep_strobe) begin
/* debuging sync pulses
			strobe <= 15;

			angle0 <= {
				valid0, 2'b0, skip0,
				3'b0, data0,
				3'b0, axis0,
				sync0[11+4:4]
			};

			angle1 <= {
				valid1, 2'b0, skip1,
				3'b0, data1,
				3'b0, axis1,
				sync1[11+4:4]
			};

			angle2 <= sweep;
*/
			if (!valid0 || !valid1) begin
				// something isn't right, throw this one away
			end else
			if (skip0 && skip1) begin
				// this should never happen
			end else
			if (!skip0) begin
				// this is from motor 0
				if (axis0) begin
					angle0 <= sweep;
					strobe[0] <= 1;
				end else begin
					angle1 <= sweep;
					strobe[1] <= 1;
				end
			end else
			if (!skip1) begin
				// this is from motor 1
				if (axis1) begin
					angle2 <= sweep;
					strobe[2] <= 1;
				end else begin
					angle3 <= sweep;
					strobe[3] <= 1;
				end
			end
		end
	end

endmodule


// at 48 MHz every sync pulse is a 512 tick window
// so we only look at the top few bits,
// which encode the skip/data/axis bits:
//
// length = 3072 + axis*512 + data*1024 + skip*2048
//
// This disagrees with https://github.com/nairol/LighthouseRedox/blob/master/docs/Light%20Emissions.md
// but matches what I've seen on my lighthouses.
module lighthouse_sync_decode(
	input [23:0] sync,
	output skip,
	output data,
	output axis,
	output valid
);
	parameter MHZ = 48; // we should do something with this

	wire [8:0] sync_short = sync[8+9:9];
	assign valid = (6 <= sync_short) && (sync_short <= 13);

	wire [2:0] type = sync_short - 6;
	assign skip = type[2];
	assign data = type[1];
	assign axis = type[0];
endmodule

/*
 * Measure the raw sweep times for the sensor.
 * This also reports the lengths of the two sync pulses so that
 * the correct axis and OOTX can be assigned.

                 Sync      Data      Angle
                <----->   <-----><------------>
_____   ________       ___       _____________   ___________
     |_|        |_____|   |_____|             |_|
    Sweep        Sync0     Sync1             Sweep

 */
module lighthouse_sweep(
	input clk,
	input reset,
	input raw_pin,
	output reg [WIDTH-1:0] sync0,
	output reg [WIDTH-1:0] sync1,
	output reg [WIDTH-1:0] sweep,
	output sweep_strobe
);
	parameter WIDTH = 24;
	parameter CLOCKS_PER_MICROSECOND = 48;

	wire rise_strobe;
	wire fall_strobe;
	reg [WIDTH-1:0] counter;
	reg [WIDTH-1:0] last_rise;
	reg [WIDTH-1:0] last_fall;
	reg got_sweep;
	reg got_sync1;

	// time low
	wire [WIDTH-1:0] len = counter - last_fall;
	wire [WIDTH-1:0] duty = counter - last_rise;

	edge_capture edge(
		.clk(clk),
		.reset(reset),
		.raw_pin(raw_pin),
		.rise_strobe(rise_strobe),
		.fall_strobe(fall_strobe)
	);

	always @(posedge clk)
	begin
		sweep_strobe <= 0;
		counter <= counter + 1;

		if (reset)
		begin
			counter <= 0;
			last_fall <= 0;
			last_rise <= 0;
			got_sweep <= 0;
			got_sync1 <= 0;
		end else
		if (fall_strobe)
		begin
			// record the time of the falling strobe
			last_fall <= counter;
		end else
		if (rise_strobe)
		begin
			if (len < 15 * CLOCKS_PER_MICROSECOND) begin
				// signal that we have something
				// if we've seen the sync pulses
				if (got_sync1)
					sweep_strobe <= 1;

				// time is from the last rising edge to
				// the midpoint of the sweep pulse
				sweep <= counter - len/2 - last_rise;
				//sweep <= duty;

				// indicate that we have a sweep
				got_sweep <= 1;
				got_sync1 <= 0;
			end else
			if (got_sweep) begin
				// first non-sweep pulse after a sweep
				sync0 <= len;
				got_sweep <= 0;
				got_sync1 <= 0;
			end else begin
				// second non-sweep pulse
				sync1 <= len;
				got_sync1 <= 1;
			end

			last_rise <= counter;
		end
	end

endmodule


module edge_capture(
	input clk,
	input reset,
	input raw_pin,
	output rise_strobe,
	output fall_strobe
);
	reg pin0;
	reg pin1;
	reg pin2;

	always @(posedge clk)
	begin
		// defaults
		rise_strobe <= 0;
		fall_strobe <= 0;

		// flop the raw pin the ensure stability
		pin0 <= raw_pin;
		pin1 <= pin0;
		pin2 <= pin1;

		if (reset) begin
			// nothing to do
		end else
		if (pin2 != pin1) begin
			rise_strobe <= !pin2;
			fall_strobe <=  pin2;
		end
	end

endmodule
