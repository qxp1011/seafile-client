//
//  FinderSync.m
//  seafile-client-fsplugin
//
//  Created by Chilledheart on 1/10/15.
//  Copyright (c) 2015 Haiwen. All rights reserved.
//

#import "FinderSync.h"
#import "FinderSyncClient.h"

enum SyncState {
    SYNC_STATE_DISABLED,
    SYNC_STATE_WAITING,
    SYNC_STATE_INIT,
    SYNC_STATE_ING,
    SYNC_STATE_DONE,
    SYNC_STATE_ERROR,
    SYNC_STATE_UNKNOWN,
};

@interface FinderSync ()

@property(readwrite, nonatomic, strong) NSURL *seafileFolderURL;
@property(readwrite, nonatomic, strong) FinderSyncClient *client;
@end

@implementation FinderSync

- (instancetype)init {
  self = [super init];

  NSLog(@"%s launched from %@ ; compiled at %s", __PRETTY_FUNCTION__,
        [[NSBundle mainBundle] bundlePath], __TIME__);

  // Set up client
  self.client = [[FinderSyncClient alloc] init];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0),
                                           ^{
                                           [self.client getWatchSet];
                                           });

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(processNotification:)
             name:kOnUpdateWatchSetNotification
           object:self.client];

  [FIFinderSyncController defaultController].directoryURLs = nil;

  return self;
}

- (void)dealloc {
  if (self.client) {
    [self.client release];
  }
  [super dealloc];
  NSLog(@"%s unloaded ; compiled at %s", __PRETTY_FUNCTION__, __TIME__);
}

#pragma mark - Primary Finder Sync protocol methods

- (void)beginObservingDirectoryAtURL:(NSURL *)url {
  // The user is now seeing the container's contents.
  // If they see it in more than one view at a time, we're only told once.
  NSLog(@"beginObservingDirectoryAtURL:%@", url.filePathURL);
}

- (void)endObservingDirectoryAtURL:(NSURL *)url {
  // The user is no longer seeing the container's contents.
  NSLog(@"endObservingDirectoryAtURL:%@", url.filePathURL);
}

- (void)requestBadgeIdentifierForURL:(NSURL *)url {
  NSLog(@"requestBadgeIdentifierForURL:%@", url.filePathURL);

  // For demonstration purposes, this picks one of our two badges, or no badge
  // at all, based on the filename.
  NSInteger whichBadge = [url.filePathURL hash] % 3;
  NSString *badgeIdentifier = @[ @"", @"Okay", @"Busy" ][whichBadge];
  [[FIFinderSyncController defaultController] setBadgeIdentifier:badgeIdentifier
                                                          forURL:url];
}

#pragma mark - Menu and toolbar item support

- (NSString *)toolbarItemName {
  return @"Seafile FinderSync";
}

- (NSString *)toolbarItemToolTip {
  return @"Seafile FinderSync: Click the toolbar item for a menu.";
}

- (NSImage *)toolbarItemImage {
  return [NSImage imageNamed:NSImageNameFolder];
}

- (NSMenu *)menuForMenuKind:(FIMenuKind)whichMenu {
  // Produce a menu for the extension.
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
  [menu addItemWithTitle:@"Example Menu Item"
                  action:@selector(sampleAction:)
           keyEquivalent:@""];

  return menu;
}

- (IBAction)sampleAction:(id)sender {
  NSURL *target = [[FIFinderSyncController defaultController] targetedURL];
  NSArray *items =
      [[FIFinderSyncController defaultController] selectedItemURLs];

  NSLog(@"sampleAction: menu item: %@, target = %@, items = ", [sender title],
        [target filePathURL]);
  [items enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
    NSLog(@"    %@", [obj filePathURL]);
  }];
}

- (void)processNotification:(NSNotification *)notification {
  // notification.userInfo;
  NSLog(@"update watch set event");
  // Set up the directory we are syncing.
  self.seafileFolderURL =
      [NSURL fileURLWithPath:@"/Users/Shared/untitled folder"];

  [FIFinderSyncController defaultController].directoryURLs =
      [NSSet setWithObject:self.seafileFolderURL];

  // Set up images for our badge identifiers. For demonstration purposes, this
  // uses off-the-shelf images.
  [[FIFinderSyncController defaultController]
           setBadgeImage:[NSImage imageNamed:NSImageNameStatusAvailable]
                   label:@"Status Okay"
      forBadgeIdentifier:@"Okay"];
  [[FIFinderSyncController defaultController]
           setBadgeImage:[NSImage
                             imageNamed:NSImageNameStatusPartiallyAvailable]
                   label:@"Status Busy"
      forBadgeIdentifier:@"Busy"];
  [[FIFinderSyncController defaultController]
           setBadgeImage:[NSImage imageNamed:NSImageNameStatusNone]
                   label:@"Status Unavailable"
      forBadgeIdentifier:@"Unavailable"];
}

@end
