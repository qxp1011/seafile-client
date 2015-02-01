//
//  FinderSync.m
//  seafile-client-fsplugin
//
//  Created by Chilledheart on 1/10/15.
//  Copyright (c) 2015 Haiwen. All rights reserved.
//

#import "FinderSync.h"
#import "FinderSyncClient.h"

@interface FinderSync ()

@property(readwrite, nonatomic) FinderSyncClient *client;
@property(readwrite, nonatomic, strong) NSTimer *timer;
@end

@implementation FinderSync

static std::vector<LocalRepo> repos;

- (instancetype)init {
  self = [super init];

  NSLog(@"%s launched from %@ ; compiled at %s", __PRETTY_FUNCTION__,
        [[NSBundle mainBundle] bundlePath], __TIME__);

  // Set up client
  self.client = new FinderSyncClient(self);
  self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0
    target:self
    selector:@selector(requestUpdateWatchSet)
    userInfo:nil
    repeats:YES];

  [FIFinderSyncController defaultController].directoryURLs = nil;

  return self;
}

- (void)dealloc {
  delete self.client;
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
  const char *filePath = url.fileSystemRepresentation;
  NSLog(@"requestBadgeIdentifierFor:%s", filePath);

  const LocalRepo *current = nullptr;
  for (const LocalRepo &repo : repos) {
    if (0 == strncmp(repo.worktree.c_str(), filePath, repo.worktree.size())) {
      current = &repo;
      break;
    }
  }
  // if not found, unset it
  if (!current) {
    [[FIFinderSyncController defaultController] setBadgeIdentifier:@""
                                                            forURL:url];
    return;
  }

  NSString *badgeIdentifier = @[
    @"DISABLED",
    @"WAITING",
    @"INIT",
    @"ING",
    @"DONE",
    @"ERROR",
    @"UNKNOWN"
  ][current->status];

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
  [menu addItemWithTitle:@"Get Share Link"
                  action:@selector(shareLinkAction:)
           keyEquivalent:@""];

  return menu;
}

- (IBAction)shareLinkAction:(id)sender {
  NSURL *target = [[FIFinderSyncController defaultController] targetedURL];
  NSArray *items =
      [[FIFinderSyncController defaultController] selectedItemURLs];

  NSLog(@"sampleAction: menu item: %@, target = %@, items = ", [sender title],
        [target filePathURL]);
  [items enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      NSLog(@"    %@", [obj filePathURL]);
  }];
}

- (void)requestUpdateWatchSet {
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0),
      ^{ self.client->getWatchSet(); });
}

- (void)updateWatchSet:(void *)new_repos {
  // notification.userInfo;
  NSLog(@"update watch set event");
  repos = std::move(*(std::vector<LocalRepo> *)new_repos);
  NSMutableArray *array = [NSMutableArray arrayWithCapacity:repos.size()];
  for (const LocalRepo &repo : repos) {
    [array addObject:[NSURL fileURLWithFileSystemRepresentation:repo.worktree
                                                                    .c_str()
                                                    isDirectory:TRUE
                                                  relativeToURL:nil]];
  }

  [FIFinderSyncController defaultController].directoryURLs =
      [NSSet setWithArray:array];

  static BOOL initialized = FALSE;
  if (!initialized) {
    initialized = TRUE;

    // Set up images for our badge identifiers. For demonstration purposes, this
    // uses off-the-shelf images.
    // DISABLED
    [[FIFinderSyncController defaultController]
             setBadgeImage:[NSImage imageNamed:NSImageNameStatusNone]
                     label:@"Status Disabled"
        forBadgeIdentifier:@"DISABLED"];
    // WAITING,
    [[FIFinderSyncController defaultController]
             setBadgeImage:[NSImage
                               imageNamed:NSImageNameStatusPartiallyAvailable]
                     label:@"Status Waiting"
        forBadgeIdentifier:@"WAITING"];
    // INIT,
    [[FIFinderSyncController defaultController]
             setBadgeImage:[NSImage
                               imageNamed:NSImageNameStatusPartiallyAvailable]
                     label:@"Status Init"
        forBadgeIdentifier:@"INIT"];
    // ING,
    [[FIFinderSyncController defaultController]
             setBadgeImage:[NSImage imageNamed:NSImageNameStatusPartiallyAvailable]
                     label:@"Status Ing"
        forBadgeIdentifier:@"ING"];
    // DONE,
    [[FIFinderSyncController defaultController]
             setBadgeImage:[NSImage imageNamed:NSImageNameStatusAvailable]
                     label:@"Status Done"
        forBadgeIdentifier:@"DONE"];
    // ERROR,
    [[FIFinderSyncController defaultController]
             setBadgeImage:[NSImage imageNamed:NSImageNameCaution]
                     label:@"Status Error"
        forBadgeIdentifier:@"ERROR"];
    // UNKNOWN,
    [[FIFinderSyncController defaultController]
             setBadgeImage:[NSImage imageNamed:NSImageNameStatusNone]
                     label:@"Status Unknown"
        forBadgeIdentifier:@"UNKOWN"];
  }
}

@end
