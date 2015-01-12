//
//  FinderSyncClient.h
//  seafile-client-fsplugin
//
//  Created by Chilledheart on 1/10/15.
//  Copyright (c) 2015 Haiwen. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#include <thread>
#include <mutex>

extern NSString *const kOnUpdateWatchSetNotification;

@interface FinderSyncClient : NSObject
- (void)getWatchSet;
- (void)doSharedLink:(NSString*) fileName;
@end
