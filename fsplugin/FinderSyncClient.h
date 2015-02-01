//
//  FinderSyncClient.h
//  seafile-client-fsplugin
//
//  Created by Chilledheart on 1/10/15.
//  Copyright (c) 2015 Haiwen. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "FinderSync.h"
#include <thread>
#include <mutex>

#include <vector>
#include <string>

struct LocalRepo {
  LocalRepo() = default;
  LocalRepo(const LocalRepo &) = default;
  LocalRepo(LocalRepo &&) = default;
  enum SyncState {
    SYNC_STATE_DISABLED,
    SYNC_STATE_WAITING,
    SYNC_STATE_INIT,
    SYNC_STATE_ING,
    SYNC_STATE_DONE,
    SYNC_STATE_ERROR,
    SYNC_STATE_UNKNOWN,
  };
  std::string worktree;
  SyncState status;
};

@interface FinderSyncClient : NSObject
@property(readwrite, nonatomic, assign) FinderSync* parent;
- (void)getWatchSet;
- (void)doSharedLink:(NSString*) fileName;
@end
