#include "utils-mac.h"

#include <libkern/OSAtomic.h>
#include <AvailabilityMacros.h>
#import <Cocoa/Cocoa.h>
#include <QString>

#if !__has_feature(objc_arc)
#error this file must be built with ARC support
#endif

// borrowed from AvailabilityMacros.h
#ifndef MAC_OS_X_VERSION_10_10
#define MAC_OS_X_VERSION_10_10      101000
#endif

@interface FinderSyncServer : NSObject <NSMachPortDelegate>
@end
@interface FinderSyncServer ()
@property(readwrite, nonatomic, strong) NSPort *listenerPort;
@end

struct watch_dir_t {
    char body[256];
    int status;
};

struct mach_msg_watchdir_send_t {
    mach_msg_header_t header;
    watch_dir_t dirs[10];
};

static NSString *const kFinderSyncMachPort =
    @"com.seafile.seafile-client.findersync.machport";
static NSString *const kFinderSyncShouldExitNotification = @"FinderSyncShouldExit";
static NSThread *fsplugin_thread;
// atomic value
static int32_t fsplugin_online = 0;
static FinderSyncServer *fsplugin_server = nil;
@implementation FinderSyncServer
- (instancetype)init {
    self = [super init];
    self.listenerPort = nil;
    return self;
}
- (void)dealloc {
#if !__has_feature(objc_arc)
    if (self.listenerPort) {
        [self.listenerPort release];
    }
    [super dealloc];
#endif
}
- (void)start {
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    mach_port_t port = MACH_PORT_NULL;

    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &port);
    if (kr != KERN_SUCCESS) {
        NSLog(@"failed to allocate mach port %@", kFinderSyncMachPort);
        NSLog(@"mach error %s", mach_error_string(kr));
        kr = mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        if (kr != KERN_SUCCESS) {
          NSLog(@"failed to deallocate mach port %@", kFinderSyncMachPort);
          NSLog(@"mach error %s", mach_error_string(kr));
        }
        return;
    }

    kr = mach_port_insert_right(mach_task_self(), port, port,
                                MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
      NSLog(@"failed to insert send right to mach port %@", kFinderSyncMachPort);
      NSLog(@"mach error %s", mach_error_string(kr));
      kr = mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
      if (kr != KERN_SUCCESS) {
        NSLog(@"failed to deallocate mach port %@", kFinderSyncMachPort);
        NSLog(@"mach error %s", mach_error_string(kr));
      }
      NSLog(@"failed to allocate send right tp local mach port");
      return;
    }
    self.listenerPort = [NSMachPort portWithMachPort:port
                                             options:NSMachPortDeallocateReceiveRight];
    if (![[NSMachBootstrapServer sharedInstance] registerPort:self.listenerPort
        name:kFinderSyncMachPort]) {
        [self.listenerPort invalidate];
        NSLog(@"failed to register mach port %@", kFinderSyncMachPort);
        NSLog(@"mach error %s", mach_error_string(kr));
        return;
    }
    NSLog(@"registered mach port %u with name %@", port, kFinderSyncMachPort);
    [self.listenerPort setDelegate:self];
    [runLoop addPort:self.listenerPort forMode:NSDefaultRunLoopMode];
    while (fsplugin_online)
        [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    [self.listenerPort invalidate];
    NSLog(@"unregistered mach port %u", port);
    kr = mach_port_deallocate(mach_task_self(), port);
    if (kr != KERN_SUCCESS) {
        NSLog(@"failed to deallocate mach port %u", port);
        return;
    }
}
- (void)stop {
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)handleMachMessage:(void *)machMessage {
  mach_msg_header_t *header = static_cast<mach_msg_header_t *>(machMessage);
  NSLog(@"header id: %u, local_port: %u, remote_port:%u, bits:%u",
        header->msgh_id, header->msgh_local_port, header->msgh_remote_port,
        header->msgh_bits);

  char *body = static_cast<char *>(machMessage) + sizeof(mach_msg_header_t);
  size_t body_size = header->msgh_size;
  // TODO handle the request

  // generate reply
  mach_port_t port = header->msgh_remote_port;
  if (!port) {
    return;
  }
  mach_msg_watchdir_send_t reply_msg;
  bzero(&reply_msg, sizeof(mach_msg_header_t));
  reply_msg.header.msgh_id = header->msgh_id + 100;
  reply_msg.header.msgh_size = sizeof(reply_msg);
  reply_msg.header.msgh_local_port = MACH_PORT_NULL;
  reply_msg.header.msgh_remote_port = port;
  reply_msg.header.msgh_bits = MACH_MSGH_BITS_REMOTE(header->msgh_bits);
  for(int i = 0; i != 10; i ++) {
  strcpy(reply_msg.dirs[i].body, "Hello World\n");
  }

  // send the reply
  kern_return_t kr = mach_msg_send(&reply_msg.header);
  if (kr != MACH_MSG_SUCCESS) {
    NSLog(@"mach error %s", mach_error_string(kr));
    NSLog(@"failed to send reply to remote mach port %u", port);
    return;
  }
  NSLog(@"send reply to remote mach port %u", port);

  // destroy
  mach_msg_destroy(header);
  mach_msg_destroy(&reply_msg.header);
}

@end
namespace utils {
namespace mac {
void startFSplugin() {
    if (!fsplugin_online) {
        // this value is used in different threads
        // keep it in atomic and guarenteed by barrier for safety
        OSAtomicIncrement32Barrier(&fsplugin_online);
        fsplugin_server = [[FinderSyncServer alloc] init];
        fsplugin_thread = [[NSThread alloc] initWithTarget:fsplugin_server
          selector:@selector(start) object:nil];
        [fsplugin_thread start];
    }
}

void stopFSplugin() {
    if (fsplugin_online) {
        // this value is used in different threads
        // keep it in atomic and guarenteed by barrier for safety
        OSAtomicDecrement32Barrier(&fsplugin_online);
        // tell fsplugin_server to exit
        [fsplugin_server performSelector:@selector(stop)
          onThread:fsplugin_thread withObject:nil
          waitUntilDone:NO];
    }
}

//TransformProcessType is not encouraged to use, aha
//Sorry but not functional for OSX 10.7
void setDockIconStyle(bool hidden) {
    //https://developer.apple.com/library/mac/documentation/AppKit/Reference/NSRunningApplication_Class/Reference/Reference.html
    if (hidden) {
        [[NSApplication sharedApplication] setActivationPolicy: NSApplicationActivationPolicyAccessory];
    } else {
        [[NSApplication sharedApplication] setActivationPolicy: NSApplicationActivationPolicyRegular];
    }
}

// Yosemite uses a new url format called fileId url, use this helper to transform
// it to the old style.
// https://bugreports.qt-project.org/browse/QTBUG-40449
// NSString *fileIdURL = @"file:///.file/id=6571367.1000358";
// NSString *goodURL = [[NSURL URLWithString:fileIdURL] filePathURL];
QString get_path_from_fileId_url(const QString &url) {
    NSString *fileIdURL = [NSString stringWithCString:url.toUtf8().data()
                                    encoding:NSUTF8StringEncoding];
    NSURL *goodURL = [[NSURL URLWithString:fileIdURL] filePathURL];
    NSString *filePath = goodURL.path; // readonly

    QString retval = QString::fromUtf8([filePath UTF8String],
                                       [filePath lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    return retval;
}

// original idea come from growl framework
// http://growl.info/about
bool get_auto_start()
{
    NSURL *itemURL = [[NSBundle mainBundle] bundleURL];
    Boolean found = false;
    CFURLRef URLToToggle = (CFURLRef)CFBridgingRetain(itemURL);
    LSSharedFileListRef loginItems = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (loginItems) {
        UInt32 seed = 0U;
        NSArray *currentLoginItems = CFBridgingRelease((LSSharedFileListCopySnapshot(loginItems, &seed)));
        for (id itemObject in currentLoginItems) {
            LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFBridgingRetain(itemObject);

            UInt32 resolutionFlags = kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes;
            CFURLRef URL = NULL;
#if (__MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_10)
            CFErrorRef err;
            URL = LSSharedFileListItemCopyResolvedURL(item, resolutionFlags, &err);
            if (err) {
#else
            OSStatus err = LSSharedFileListItemResolve(item, resolutionFlags, &URL, /*outRef*/ NULL);
            if (err == noErr) {
#endif
                found = CFEqual(URL, URLToToggle);
                CFRelease(URL);

                if (found)
                    break;
            }
        }
        CFRelease(loginItems);
    }
    return found;
}

void set_auto_start(bool enabled)
{
    NSURL *itemURL = [[NSBundle mainBundle] bundleURL];
    OSStatus status;
    CFURLRef URLToToggle = (CFURLRef)CFBridgingRetain(itemURL);
    LSSharedFileListItemRef existingItem = NULL;
    LSSharedFileListRef loginItems = LSSharedFileListCreate(kCFAllocatorDefault, kLSSharedFileListSessionLoginItems, /*options*/ NULL);
    if(loginItems)
    {
        UInt32 seed = 0U;
        NSArray *currentLoginItems = CFBridgingRelease(LSSharedFileListCopySnapshot(loginItems, &seed));
        for (id itemObject in currentLoginItems) {
            LSSharedFileListItemRef item = (LSSharedFileListItemRef)CFBridgingRetain(itemObject);

            UInt32 resolutionFlags = kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes;
            CFURLRef URL = NULL;
#if (__MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_10)
            CFErrorRef err;
            URL = LSSharedFileListItemCopyResolvedURL(item, resolutionFlags, &err);
            if (err) {
#else
            OSStatus err = LSSharedFileListItemResolve(item, resolutionFlags, &URL, /*outRef*/ NULL);
            if (err == noErr) {
#endif
                Boolean found = CFEqual(URL, URLToToggle);
                CFRelease(URL);

                if (found) {
                    existingItem = item;
                    break;
                }
            }
        }

        if (enabled && (existingItem == NULL)) {
            NSString *displayName = @"Seafile Client";
            IconRef icon = NULL;
            FSRef ref;
            //TODO: replace the deprecated CFURLGetFSRef
            Boolean gotRef = CFURLGetFSRef(URLToToggle, &ref);
            if (gotRef) {
                status = GetIconRefFromFileInfo(&ref,
                                                /*fileNameLength*/ 0,
                                                /*fileName*/ NULL,
                                                kFSCatInfoNone,
                                                /*catalogInfo*/ NULL,
                                                kIconServicesNormalUsageFlag,
                                                &icon,
                                                /*outLabel*/ NULL);
                if (status != noErr)
                    icon = NULL;
            }

            LSSharedFileListInsertItemURL(loginItems, kLSSharedFileListItemBeforeFirst,
                  (CFStringRef)CFBridgingRetain(displayName), icon, URLToToggle,
                  /*propertiesToSet*/ NULL, /*propertiesToClear*/ NULL);
          } else if (!enabled && (existingItem != NULL))
              LSSharedFileListItemRemove(loginItems, existingItem);

        CFRelease(loginItems);
    }
}

} // namespace mac
} // namespace utils
