//
//  FinderSyncClient.m
//  seafile-client-fsplugin
//
//  Created by Chilledheart on 1/10/15.
//  Copyright (c) 2015 Haiwen. All rights reserved.
//

#import "FinderSyncClient.h"
#include <servers/bootstrap.h>

static NSString *const kFinderSyncMachPort =
    @"com.seafile.seafile-client.findersync.machport";
NSString *const kOnUpdateWatchSetNotification = @"OnUpdateWatchSet";

static const int watch_dir_maxsize = 100;

struct watch_dir_t {
  char body[256];
  int status;
};

struct mach_msg_watchdir_rcv_t {
  mach_msg_header_t header;
  watch_dir_t dirs[watch_dir_maxsize];
  mach_msg_trailer_t trailer;
};

@interface FinderSyncClient ()

@property(readwrite, nonatomic) mach_port_t remotePort;
@property(readwrite, nonatomic) mach_port_t localPort;

@end

@implementation FinderSyncClient

- (instancetype)init {
  self = [super init];
  self.remotePort = MACH_PORT_NULL;
  self.localPort = nil;
  return self;
}

- (void)dealloc {
  if (self.localPort) {
    NSLog(@"disconnected from mach port %@", kFinderSyncMachPort);
    mach_port_mod_refs(mach_task_self(), self.localPort,
                       MACH_PORT_RIGHT_RECEIVE, -1);
    self.localPort = nil;
  }
  if (self.remotePort) {
    NSLog(@"disconnected from mach port %@", kFinderSyncMachPort);
    mach_port_deallocate(mach_task_self(), self.remotePort);
  }
  [super dealloc];
}

- (BOOL)connect {
  if (!self.localPort) {

    // Create a local port.
    mach_port_t port;
    kern_return_t kr =
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (kr != KERN_SUCCESS) {
      NSLog(@"failed to connect local mach port");
      return FALSE;
    }
    self.localPort = port;
    NSLog(@"connected to local mach port %u", port);
  }

  if (!self.remotePort) {
    // connect to the mach_port
    mach_port_t port;

    kern_return_t kr = bootstrap_look_up(
        bootstrap_port,
        [kFinderSyncMachPort cStringUsingEncoding:NSASCIIStringEncoding],
        &port);

    if (kr != KERN_SUCCESS) {
      NSLog(@"failed to connect remote mach port");
      return FALSE;
    }
    self.remotePort = port;

    NSLog(@"connected to remote mach port %u", self.remotePort);
  }

  return TRUE;
}

- (void)getWatchSet {
  if ([NSThread isMainThread]) {
    NSLog(@"%s isn't supported to be called from main thread",
          __PRETTY_FUNCTION__);
    return;
  }
  if (![self connect]) {
    return;
  }
  mach_port_t local_port = self.localPort;
  mach_port_t remote_port = self.remotePort;
  mach_msg_empty_send_t msg;
  bzero(&msg, sizeof(mach_msg_header_t));
  msg.header.msgh_id = 0;
  msg.header.msgh_local_port = local_port;
  msg.header.msgh_remote_port = remote_port;
  msg.header.msgh_size = sizeof(msg);
  msg.header.msgh_bits =
      MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
  // send a message and wait for the reply
  kern_return_t kr = mach_msg(&msg.header,                       /* header*/
                              MACH_SEND_MSG | MACH_SEND_TIMEOUT, /*option*/
                              sizeof(msg),                       /*send size*/
                              0,               /*receive size*/
                              local_port,      /*receive port*/
                              100,             /*timeout, in milliseconds*/
                              MACH_PORT_NULL); /*no notification*/
  if (kr != MACH_MSG_SUCCESS) {
    NSLog(@"failed to send getWatchSet request to remote mach port %u",
          remote_port);
    NSLog(@"mach error %s", mach_error_string(kr));
    return;
  }
  NSLog(@"sent getWatchSet request to remote mach port %u", remote_port);

  mach_msg_watchdir_rcv_t recv_msg;
  bzero(&recv_msg, sizeof(mach_msg_header_t));
  recv_msg.header.msgh_local_port = local_port;
  recv_msg.header.msgh_remote_port = remote_port;
  // recv_msg.header.msgh_size = sizeof(recv_msg);
  // receive the reply
  kr = mach_msg(&recv_msg.header,                /* header*/
                MACH_RCV_MSG | MACH_RCV_TIMEOUT, /*option*/
                0,                               /*send size*/
                sizeof(recv_msg),                /*receive size*/
                local_port,                      /*receive port*/
                100,                             /*timeout, in milliseconds*/
                MACH_PORT_NULL);                 /*no notification*/
  if (kr != MACH_MSG_SUCCESS) {
    NSLog(@"failed to receive getWatchSet reply from remote mach port %u",
          remote_port);
    NSLog(@"mach error %s", mach_error_string(kr));
    return;
  }
  size_t count = (recv_msg.header.msgh_size - sizeof(mach_msg_header_t)) /
    sizeof(watch_dir_t);
  for (size_t i = 0; i != count; i++) {
    NSLog(@"%s", recv_msg.dirs[i].body);
    NSLog(@"statuc %u", recv_msg.dirs[i].status);
  }
  NSLog(@"received getWatchSet reply from remote mach port %u", remote_port);
}

- (void)doSharedLink:(NSString *)fileName {
  if ([NSThread isMainThread]) {
    NSLog(@"%s isn't supported to be called from main thread",
          __PRETTY_FUNCTION__);
    return;
  }
  if (![self connect]) {
    return;
  }
  mach_msg_empty_send_t msg;
  bzero(&msg, sizeof(msg));
  msg.header.msgh_id = 1;
  msg.header.msgh_local_port = MACH_PORT_NULL;
  msg.header.msgh_remote_port = self.remotePort;
  msg.header.msgh_size = sizeof(msg);
  msg.header.msgh_bits = MACH_MSGH_BITS_REMOTE(MACH_MSG_TYPE_COPY_SEND);
  // send a message only
  kern_return_t kr = mach_msg_send(&msg.header);
  if (kr != MACH_MSG_SUCCESS) {
    NSLog(@"failed to send doSharedLink to remote mach port %u",
          self.remotePort);
    NSLog(@"mach error %s", mach_error_string(kr));
    return;
  }
  NSLog(@"sent doSharedLink request to remote mach port %u", self.remotePort);
}

@end
