//
//  FinderSyncClient.m
//  seafile-client-fsplugin
//
//  Created by Chilledheart on 1/10/15.
//  Copyright (c) 2015 Haiwen. All rights reserved.
//

#import "FinderSyncClient.h"
#include <servers/bootstrap.h>

namespace {
NSString *const kFinderSyncMachPort =
    @"com.seafile.seafile-client.findersync.machport";

const int kWatchDirMax = 100;
const int kPathMaxSize = 256;
}

enum CommandType {
  GetWatchSet = 0,
  DoShareLink,
};

struct mach_msg_command_send_t {
  mach_msg_header_t header;
  char body[kPathMaxSize];
  int command;
};

struct watch_dir_t {
  char body[kPathMaxSize];
  int status;
};

struct mach_msg_watchdir_rcv_t {
  mach_msg_header_t header;
  watch_dir_t dirs[kWatchDirMax];
  mach_msg_trailer_t trailer;
};

FinderSyncClient::FinderSyncClient(FinderSync *parent)
    : parent_(parent), local_port_(MACH_PORT_NULL),
      remote_port_(MACH_PORT_NULL) {}

FinderSyncClient::~FinderSyncClient() {
  if (local_port_) {
    NSLog(@"disconnected from mach port %@", kFinderSyncMachPort);
    mach_port_mod_refs(mach_task_self(), local_port_, MACH_PORT_RIGHT_RECEIVE,
                       -1);
  }
  if (remote_port_) {
    NSLog(@"disconnected from mach port %@", kFinderSyncMachPort);
    mach_port_deallocate(mach_task_self(), remote_port_);
  }
}

void FinderSyncClient::connectionBecomeInvalid() {
  if (remote_port_) {
    mach_port_deallocate(mach_task_self(), remote_port_);
    dispatch_async(dispatch_get_main_queue(), ^{
        std::vector<LocalRepo> repos;
        [parent_ updateWatchSet:&repos];
    });
    remote_port_ = MACH_PORT_NULL;
  }
}

bool FinderSyncClient::connect() {
  if (!local_port_) {

    // Create a local port.
    mach_port_t port;
    kern_return_t kr =
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (kr != KERN_SUCCESS) {
      NSLog(@"failed to connect local mach port");
      return FALSE;
    }
    local_port_ = port;
    NSLog(@"connected to local mach port %u", port);
  }

  if (!remote_port_) {
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
    remote_port_ = port;

    NSLog(@"connected to remote mach port %u", remote_port_);
  }

  return TRUE;
}

void FinderSyncClient::getWatchSet() {
  if ([NSThread isMainThread]) {
    NSLog(@"%s isn't supported to be called from main thread",
          __PRETTY_FUNCTION__);
    return;
  }
  if (!connect()) {
    return;
  }
  mach_msg_command_send_t msg;
  bzero(&msg, sizeof(mach_msg_header_t));
  msg.header.msgh_id = 0;
  msg.header.msgh_local_port = local_port_;
  msg.header.msgh_remote_port = remote_port_;
  msg.header.msgh_size = sizeof(msg);
  msg.header.msgh_bits =
      MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
  msg.command = GetWatchSet;
  // send a message and wait for the reply
  kern_return_t kr = mach_msg(&msg.header,                       /* header*/
                              MACH_SEND_MSG | MACH_SEND_TIMEOUT, /*option*/
                              sizeof(msg),                       /*send size*/
                              0,               /*receive size*/
                              local_port_,     /*receive port*/
                              100,             /*timeout, in milliseconds*/
                              MACH_PORT_NULL); /*no notification*/
  if (kr != MACH_MSG_SUCCESS) {
    NSLog(@"failed to send getWatchSet request to remote mach port %u",
          remote_port_);
    NSLog(@"mach error %s", mach_error_string(kr));
    if (kr == MACH_SEND_INVALID_DEST)
      connectionBecomeInvalid();
    return;
  }

  mach_msg_watchdir_rcv_t recv_msg;
  bzero(&recv_msg, sizeof(mach_msg_header_t));
  recv_msg.header.msgh_local_port = local_port_;
  recv_msg.header.msgh_remote_port = remote_port_;
  // recv_msg.header.msgh_size = sizeof(recv_msg);
  // receive the reply
  kr = mach_msg(&recv_msg.header,                /* header*/
                MACH_RCV_MSG | MACH_RCV_TIMEOUT, /*option*/
                0,                               /*send size*/
                sizeof(recv_msg),                /*receive size*/
                local_port_,                     /*receive port*/
                100,                             /*timeout, in milliseconds*/
                MACH_PORT_NULL);                 /*no notification*/
  if (kr != MACH_MSG_SUCCESS) {
    NSLog(@"failed to receive getWatchSet reply from remote mach port %u",
          remote_port_);
    NSLog(@"mach error %s", mach_error_string(kr));
    return;
  }
  size_t count = (recv_msg.header.msgh_size - sizeof(mach_msg_header_t)) /
                 sizeof(watch_dir_t);
  dispatch_async(dispatch_get_main_queue(), ^{
      std::vector<LocalRepo> repos;
      for (size_t i = 0; i != count; i++) {
        LocalRepo repo;
        repo.worktree = recv_msg.dirs[i].body;
        repo.status =
            static_cast<LocalRepo::SyncState>(recv_msg.dirs[i].status);
        repos.emplace_back(std::move(repo));
      }
      [parent_ updateWatchSet:&repos];
  });
}

void FinderSyncClient::doSharedLink(const char *fileName) {
  if ([NSThread isMainThread]) {
    NSLog(@"%s isn't supported to be called from main thread",
          __PRETTY_FUNCTION__);
    return;
  }
  if (!connect()) {
    return;
  }
  mach_msg_command_send_t msg;
  bzero(&msg, sizeof(msg));
  msg.header.msgh_id = 1;
  msg.header.msgh_local_port = MACH_PORT_NULL;
  msg.header.msgh_remote_port = remote_port_;
  msg.header.msgh_size = sizeof(msg);
  msg.header.msgh_bits = MACH_MSGH_BITS_REMOTE(MACH_MSG_TYPE_COPY_SEND);
  strncpy(msg.body, fileName, kPathMaxSize);
  msg.command = DoShareLink;
  // send a message only
  kern_return_t kr = mach_msg_send(&msg.header);
  if (kr != MACH_MSG_SUCCESS) {
    NSLog(@"failed to send doSharedLink %s to remote mach port %u", fileName,
          remote_port_);
    NSLog(@"mach error %s", mach_error_string(kr));
    if (kr == MACH_SEND_INVALID_DEST)
      connectionBecomeInvalid();
    return;
  }
  NSLog(@"sent doSharedLink %s to remote mach port %u", fileName, remote_port_);
}
