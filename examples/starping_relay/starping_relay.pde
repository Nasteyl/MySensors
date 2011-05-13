/*
 Copyright (C) 2011 James Coliz, Jr. <maniacbug@ymail.com>
 
 This program is free software; you can redistribute it and/or
 modify it under the terms of the GNU General Public License
 version 2 as published by the Free Software Foundation.
 */

/**
 * Example RF Radio Ping Star Group with Relay 
 *
 * This sketch is a more complex example of using the RF24 library for Arduino.  
 * Deploy this on up to six nodes.  Set one as the 'pong receiver' by tying the 
 * role_pin low, and the others will be 'ping transmit' units.  The ping units
 * unit will send out the value of millis() once a second.  The pong unit will 
 * respond back with a copy of the value.  Each ping unit can get that response
 * back, and determine how long the whole cycle took.
 *
 * This example introduces a new role, the 'relay', which can relay pings or
 * pongs from one host to another.  This is needed in larger meshes because
 * each radio can only listen to 5-6 others.
 *
 * This example requires a bit more complexity to determine which unit is which.
 * The pong receiver is identified by having its role_pin tied to ground.
 * The ping senders are further differentiated by a byte in eeprom.
 */
 
#include <SPI.h>
#include <EEPROM.h>
#include "nRF24L01.h"
#include "RF24.h"
#include "printf.h"

//
// Hardware configuration
//

// Set up nRF24L01 radio on SPI bus plus pins 8 & 9

RF24 radio(8,9);

//
// Topology
//

// Radio pipe addresses for the nodes to communicate.  Only ping nodes need
// dedicated pipes in this topology.  Each ping node has a talking pipe
// that it will ping into, and a listening pipe that it will listen for
// the pong.  The pong node listens on all the ping node talking pipes
// and sends the pong back on the sending node's specific listening pipe.

struct node_info
{
  uint64_t talking_pipe; // Pipe used to talk to parent node
  uint64_t listening_pipe; // Pipe used to listen to parent node
  uint8_t parent_node; // Number of parent node
};

const node_info topology[] =
{
  { 0x0000000000LL, 0x0000000000LL,-1 }, // Base
  { 0xF0F0F0F0E1LL, 0x3A3A3A3AE1LL, 0 }, // Relay
  { 0xF0F0F0F0D2LL, 0x3A3A3A3AD2LL, 1 }, // Leaf
  { 0xF0F0F0F0C3LL, 0x3A3A3A3AC3LL, 1 }, // Leaf
  { 0xF0F0F0F0B4LL, 0x3A3A3A3AB4LL, 1 }, // Leaf
  { 0xF0F0F0F0A5LL, 0x3A3A3A3AA5LL, 0 }, // Leaf, direct to Base
};
const short num_nodes = sizeof(topology)/sizeof(node_info);

//
// Role management
//
// Set up role.  This sketch uses the same software for all the nodes
// in this system.  Doing so greatly simplifies testing.  The hardware itself specifies
// which node it is.
//
// This is done through the role_pin
//

// The various roles supported by this sketch
typedef enum { role_invalid = 0, role_base, role_relay, role_leaf } role_e;

// The debug-friendly names of those roles
const char* role_friendly_name[] = { "invalid", "Base", "Relay", "Leaf" };

// The role of the current running sketch
role_e role;

//
// Address management
//

// Where in EEPROM is the address stored?
const uint8_t address_at_eeprom_location = 0;

// What flag value is stored there so we know the value is valid?
const uint8_t valid_eeprom_flag = 0xdf;

// What is our address (SRAM cache of the address from EEPROM)
// This is an index into the topology[] table above
uint8_t node_address = role_invalid;;

//
// Payload
//

struct payload_t
{
  uint8_t from_node;
  uint8_t to_node;
  unsigned long time;
};

void payload_printf(const char* name, const payload_t& pl)
{
  printf("%s Payload from:%u to:%u time:%lu",name,pl.from_node,pl.to_node,pl.time);
}

void setup(void)
{
  //
  // Address
  //

  // Unless we find reasonable values in the EEPROM, these are the defaults
  node_address = -1;

  // Look for the token in EEPROM to indicate the following value is
  // a validly set node address 
  if ( EEPROM.read(address_at_eeprom_location) == valid_eeprom_flag )
  {
    // Read the address from EEPROM
    uint8_t reading = EEPROM.read(address_at_eeprom_location+1);

    // If it is in a valid range for node addresses, it is our
    // address.
    if ( reading <= 5 )
      node_address = reading;
  } 
  
  //
  // Role
  //

  // Role is determined by address.
  if ( node_address != -1 )
  {
    // Node #0 is the base, by definition
    if ( node_address == 0 )
      role = role_base;
    else
    {
      // Otherwise, it is probably a leaf node
      role = role_leaf;

      // If there are any nodes in the topology table which consider this
      // a parent, then we are a relay.
      int i = num_nodes;
      while (i--)
      {
      	if ( topology[i].parent_node == node_address )
	{
	  role = role_relay;
	  break;
	}
      }
    }
  }

  //
  // Print preamble
  //
  
  Serial.begin(9600);
  printf_begin();
  printf("\n\rRF24/examples/starping_relay/\n\r");
  printf("ROLE: %s\n\r",role_friendly_name[role]);
  printf("ADDRESS: %i\n\r",node_address);

  //
  // Setup and configure rf radio
  //
  
  radio.begin();

  //
  // Open pipes to other nodes for communication
  //
  
  // First listening pipe is #1
  uint8_t current_pipe = 1;
  
  // Each leaf node has a talking pipe that it will ping into, and a listening 
  // pipe that it will listen for the pong.  Relay nodes also do this.
  if ( role == role_leaf || role == role_relay )
  {
    // Write on our talking pipe
    radio.openWritingPipe(topology[node_address].talking_pipe);

    // Listen on our listening pipe 
    radio.openReadingPipe(current_pipe++,topology[node_address].listening_pipe);
  }

  // The base and relay nodes listens on all their children node's talking pipes
  // and sends the pong back on the child node's specific listening pipe.
  if ( role == role_base || role == role_relay )
  {
    // The topology table tells us who our children are
    int i = num_nodes;
    while (i--)
    {
      if ( topology[i].parent_node == node_address )
	radio.openReadingPipe(current_pipe++,topology[i].talking_pipe);
    }
  }
  
  //
  // Start listening
  //
  
  radio.startListening();
  
  //
  // Dump the configuration of the rf unit for debugging
  //
  
  radio.printDetails();

  //
  // Prompt the user to assign a node address if we don't have one
  //

  if ( role == role_invalid )
  {
    printf("\n\r*** NO NODE ADDRESS ASSIGNED *** Send 1 through 6 to assign an address\n\r");
  }
}

void loop(void)
{
  //
  // Leaf role.  Repeatedly send the current time
  //
  
  if ( role == role_leaf ) 
  {
    // First, stop listening so we can talk.
    radio.stopListening();
    
    // Take the time, and send it.  This will block until complete
    payload_t ping;
    ping.time = millis();
    ping.from_node = node_address;
    ping.to_node = 0; // All pings go to the base

    payload_printf("PING",ping);
    radio.write( &ping, sizeof(payload_t) );  
    
    // Now, continue listening
    radio.startListening();
    
    // Wait here until we get a response, or timeout (250ms)
    unsigned long started_waiting_at = millis();
    bool timeout = false;
    while ( ! radio.available() && ! timeout )
      if (millis() - started_waiting_at > 250 )
        timeout = true;
    
    // Describe the results
    if ( timeout )
    {
      printf("Failed, response timed out.\n\r");
    }
    else
    {
      // Grab the response, compare, and send to debugging spew
      payload_t pong;
      radio.read( &pong, sizeof(payload_t) );
  
      // Spew it
      payload_printf(" ...PONG",pong);
      printf(" Round-trip delay: %lu\n\r",millis()-pong.time);
    }
    
    // Try again 1s later
    delay(1000);
  }
  
  //
  // Base role.  Receive each packet, dump it out, and send it back
  //
  
  if ( role == role_base )
  {
    // if there is data ready
    uint8_t pipe_num;
    if ( radio.available(&pipe_num) )
    {
      // Dump the payloads until we've gotten everything
      payload_t ping;
      boolean done = false;
      while (!done)
      {
        // Fetch the payload, and see if this was the last one.
        done = radio.read( &ping, sizeof(payload_t) );
  
        // Spew it
	payload_printf("PING",ping);
      }
      
      // First, stop listening so we can talk
      radio.stopListening();
      
      // Construct the return payload (pong)
      payload_t pong;
      pong.time = ping.time;
      pong.from_node = node_address;
      pong.to_node = ping.from_node;

      // Open the correct pipe for writing
      radio.openWritingPipe(topology[pong.to_node].listening_pipe);

      // Retain the low 2 bytes to identify the pipe for the spew
      uint16_t pipe_id = topology[pong.to_node].listening_pipe & 0xffff;
            
      // Send the final one back.
      radio.write( &pong, sizeof(payload_t) );  
      payload_printf(" ...PONG",pong);
      printf(" on pipe %04x.\n\r",pipe_id);
      
      // Now, resume listening so we catch the next packets.
      radio.startListening();
    }
  }

  //
  // Listen for serial input, which is how we set the address
  //
  if (Serial.available())
  {
    // If the character on serial input is in a valid range...
    char c = Serial.read();
    if ( c >= '0' && c <= '5' )
    {
      // It is our address
      EEPROM.write(address_at_eeprom_location,valid_eeprom_flag);
      EEPROM.write(address_at_eeprom_location+1,c-'0');

      // And we are done right now (no easy way to soft reset)
      printf("\n\rManually reset address to: %c\n\rPress RESET to continue!",c);
      while(1);
    }
  }
}
// vim:ai:cin:sts=2 sw=2 ft=cpp
