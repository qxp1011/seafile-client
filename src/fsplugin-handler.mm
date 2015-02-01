#include "fsplugin-handler.h"
#include <libkern/OSAtomic.h>
#import <Cocoa/Cocoa.h>

#include <QFileInfo>
#include <mutex>
#include "account.h"
#include "account-mgr.h"
#include "seafile-applet.h"
#include "rpc/local-repo.h"
#include "rpc/rpc-client.h"
#include "filebrowser/file-browser-requests.h"
#include "filebrowser/sharedlink-dialog.h"

#if !__has_feature(objc_arc)
#error this file must be built with ARC support
#endif

@interface FinderSyncServer : NSObject <NSMachPortDelegate>
@end

namespace {
const int kWatchDirMax = 100;
const int kPathMaxSize = 256;
NSString *const kFinderSyncMachPort = @"com.seafile.seafile-client.findersync.machport";
};

enum CommandType {
    GetWatchSet = 0,
    DoShareLink,
};

struct mach_msg_command_send_t {
  mach_msg_header_t header;
  char body[kPathMaxSize];
  int command;
};

struct mach_msg_command_rcv_t {
    mach_msg_header_t header;
    char body[kPathMaxSize];
    int command;
    mach_msg_trailer_t trailer;
};

struct watch_dir_t {
    char body[kPathMaxSize];
    int status;
};

struct mach_msg_watchdir_send_t {
    mach_msg_header_t header;
    watch_dir_t dirs[kWatchDirMax];
};
namespace {
NSThread *fsplugin_thread = nil;
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
    mach_msg_command_rcv_t *msg = static_cast<mach_msg_command_rcv_t *>(machMessage);
    if (msg->header.msgh_size != sizeof(mach_msg_command_send_t)) {
      NSLog(@"received msg with bad size %u from remote_port:%u",
            msg->header.msgh_size, msg->header.msgh_remote_port);
      mach_msg_destroy(&msg->header);
      return;
    }

    switch (msg->command) {
    case DoShareLink:
        NSLog(@"received DoShareLink command with %s", msg->body);
        QMetaObject::invokeMethod(fsplugin_updater.get(), "doShareLink",
                                  Qt::QueuedConnection,
                                  Q_ARG(QString, msg->body));
        mach_msg_destroy(&msg->header);
        return;
    case GetWatchSet:
        break;
    default:
        NSLog(@"received unknown command %u from remote_port:%u", msg->command,
              msg->header.msgh_remote_port);
        mach_msg_destroy(&msg->header);
        return;
    }

    // generate reply
    mach_port_t port = msg->header.msgh_remote_port;
    if (!port) {
      return;
    }
    mach_msg_watchdir_send_t reply_msg;
    size_t count = fsplugin_updater->getWatchSet(reply_msg.dirs, kWatchDirMax);
    bzero(&reply_msg, sizeof(mach_msg_header_t));
    reply_msg.header.msgh_id = msg->header.msgh_id + 100;
    reply_msg.header.msgh_size = sizeof(mach_msg_header_t) + count * sizeof(watch_dir_t);
    reply_msg.header.msgh_local_port = MACH_PORT_NULL;
    reply_msg.header.msgh_remote_port = port;
    reply_msg.header.msgh_bits = MACH_MSGH_BITS_REMOTE(msg->header.msgh_bits);

    // send the reply
    kern_return_t kr = mach_msg_send(&reply_msg.header);
    if (kr != MACH_MSG_SUCCESS) {
      NSLog(@"mach error %s", mach_error_string(kr));
      NSLog(@"failed to send reply to remote mach port %u", port);
      return;
    }

    // destroy
    mach_msg_destroy(&msg->header);
    mach_msg_destroy(&reply_msg.header);
}

@end

namespace {
std::mutex watch_set_mutex_;
std::vector<LocalRepo> watch_set_;
QHash<QString, Account> accounts_cache_;
const char *kRepoRelayAddrProperty = "relay-address";
}

Account findAccountByRepo(const QString& repo_id)
{
    SeafileRpcClient *rpc = seafApplet->rpcClient();
    if (!accounts_cache_.contains(repo_id)) {
        QString relay_addr;
        if (rpc->getRepoProperty(repo_id, kRepoRelayAddrProperty, &relay_addr) < 0) {
            return Account();
        }
        const std::vector<Account>& accounts = seafApplet->accountManager()->accounts();
        for (int i = 0; i < accounts.size(); i++) {
            const Account& account = accounts[i];
            if (account.serverUrl.host() == relay_addr) {
                accounts_cache_[repo_id] = account;
                break;
            }
        }
    }
    return accounts_cache_.value(repo_id, Account());
}


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
    std::lock_guard<std::mutex> watch_set_lock(watch_set_mutex_);

    size_t count = (watch_set_.size() > max_size) ? max_size : watch_set_.size();
    for (size_t i = 0; i != count; ++i, ++front) {
      strncpy(front->body, watch_set_[i].worktree.toUtf8().data(), kPathMaxSize);
      front->status = watch_set_[i].sync_state;
    }
    return count;
}

void FinderSyncServerUpdater::updateWatchSet() {
    std::lock_guard<std::mutex> watch_set_lock(watch_set_mutex_);

    SeafileRpcClient *rpc = seafApplet->rpcClient();

    // update watch_set_
    watch_set_.clear();
    if (rpc->listLocalRepos(&watch_set_))
        NSLog(@"update watch set failed");
    for (LocalRepo &repo : watch_set_)
        rpc->getSyncStatus(repo);

    timer_->start(1000);
}

void FinderSyncServerUpdater::doShareLink(QString path) {
    QString repo_id;
    QString repo_worktree;
    {
        std::lock_guard<std::mutex> watch_set_lock(watch_set_mutex_);
        for (LocalRepo &repo : watch_set_)
            if(path.startsWith(repo.worktree)) {
                repo_id = repo.id;
                repo_worktree = repo.worktree;
                break;
            }
    }
    if (repo_id.isEmpty() || repo_worktree == path) {
        NSLog(@"invalid path %s", path.toUtf8().data());
        return;
    }

    const Account account = findAccountByRepo(repo_id);
    if (!account.isValid()) {
        NSLog(@"invalid repo_id %s", repo_id.toUtf8().data());
        return;
    }

    QStringRef path_in_repo = path.rightRef(path.size() - repo_worktree.size());

    req.reset(new GetSharedLinkRequest(account, repo_id,
                                       QString("/").append(path_in_repo),
                                       QFileInfo(path).isFile()));

    connect(req.get(), SIGNAL(success(const QString&)),
            this, SLOT(onShareLinkGenerated(const QString&)));

    req->send();

}

void FinderSyncServerUpdater::onShareLinkGenerated(const QString& link)
{
    NSLog(@"shared link %s", link.toUtf8().data());
    SharedLinkDialog *dialog = new SharedLinkDialog(link, NULL);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->show();
    dialog->raise();
    dialog->activateWindow();
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
