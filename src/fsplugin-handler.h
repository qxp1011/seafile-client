#ifndef SEAFILE_CLIENT_FSPLUGINS_HANDLER_H_
#define SEAFILE_CLIENT_FSPLUGINS_HANDLER_H_
#include <QObject>
#include <QString>
#include <QTimer>
#include <memory>
#include <vector>

struct watch_dir_t;
class GetSharedLinkRequest;
class FinderSyncServerUpdater : public QObject {
    Q_OBJECT
public:
    FinderSyncServerUpdater();
    ~FinderSyncServerUpdater();
    // called from another thread
    size_t getWatchSet(watch_dir_t *front, size_t max_size);
private slots:
    void updateWatchSet();
    void doShareLink(QString path);
    void onShareLinkGenerated(const QString& link);
private:
    std::unique_ptr<GetSharedLinkRequest> req;
    QTimer *timer_;
};

void startFSplugin();
void stopFSplugin();

#endif // SEAFILE_CLIENT_FSPLUGINS_HANDLER_H_
