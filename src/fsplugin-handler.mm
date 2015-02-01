#include "fsplugin-handler.h"
#include <libkern/OSAtomic.h>
#import <Cocoa/Cocoa.h>

#include <memory>

#include <QMutex>
#include "seafile-applet.h"
#include "rpc/local-repo.h"
#include "rpc/rpc-client.h"

#if !__has_feature(objc_arc)
#error this file must be built with ARC support
#endif

@interface FinderSyncServer : NSObject <NSMachPortDelegate>
@end

const int watch_dir_maxsize = 100;

struct watch_dir_t {
    char body[256];
    int status;
};

struct mach_msg_watchdir_send_t {
    mach_msg_header_t header;
    watch_dir_t dirs[watch_dir_maxsize];
};
namespace {
NSString *const kFinderSyncMachPort = @"com.seafile.seafile-client.findersync.machport";
NSThread *fsplugin_thread;
// atomic value
int32_t fsplugin_online = 0;
FinderSyncServer *fsplugin_server = nil;
std::unique_ptr<FinderSyncServerUpdater> fsplugin_updater;
} // anonymous namespace

@interface FinderSyncServer ()
@property(readwrite, nonatomic, strong) NSPort *listenerPort;
@end
@implementation FinderSyncServer
- (instancetype)init {
    self = [super init];
    self.listenerPort = nil;
    return self;
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
    size_t count = fsplugin_updater->getWatchSet(reply_msg.dirs, watch_dir_maxsize);
    bzero(&reply_msg, sizeof(mach_msg_header_t));
    reply_msg.header.msgh_id = header->msgh_id + 100;
    reply_msg.header.msgh_size = sizeof(mach_msg_header_t) + count * sizeof(watch_dir_t);
    reply_msg.header.msgh_local_port = MACH_PORT_NULL;
    reply_msg.header.msgh_remote_port = port;
    reply_msg.header.msgh_bits = MACH_MSGH_BITS_REMOTE(header->msgh_bits);

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

static QMutex watch_set_mutex_;
static std::vector<LocalRepo> watch_set_;

FinderSyncServerUpdater::FinderSyncServerUpdater()
  : timer_(new QTimer(this))
{
    timer_->setSingleShot(true);
    timer_->start(2000);
    connect(timer_, SIGNAL(timeout()), this, SLOT(updateWatchSet()));
}

FinderSyncServerUpdater::~FinderSyncServerUpdater() {
    timer_->stop();
}

size_t FinderSyncServerUpdater::getWatchSet(watch_dir_t *front, size_t max_size) {
    QMutexLocker watch_set_lock(&watch_set_mutex_);

    size_t count = (watch_set_.size() > max_size) ? max_size : watch_set_.size();
    for (size_t i = 0; i != count; ++i, ++front) {
      strncpy(front->body, watch_set_[i].worktree.toUtf8().data(), 256);
      front->status = watch_set_[i].sync_state;
    }
    return count;
}

void FinderSyncServerUpdater::updateWatchSet() {
    QMutexLocker watch_set_lock(&watch_set_mutex_);

    SeafileRpcClient *rpc = seafApplet->rpcClient();

    // update watch_set_
    watch_set_.clear();
    if (rpc->listLocalRepos(&watch_set_))
        /*do some warning*/;

    timer_->start(1000);
}

void startFSplugin() {
    if (!fsplugin_online) {
        fsplugin_updater.reset(new FinderSyncServerUpdater);
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
        fsplugin_updater.release();
    }
}
