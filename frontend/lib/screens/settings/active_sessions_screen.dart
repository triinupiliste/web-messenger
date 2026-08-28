import 'package:flutter/material.dart';
import '../../constants/socket_events.dart';
import '../../services/api_service.dart';
import '../../services/socket_service.dart';
import '../../theme/app_colors.dart';

// Lets the user see every device/browser currently signed in to their account
// (e.g. mobile app + web) and selectively log one out without affecting the
// others — the mirror image of the old single-session "force logout" behavior.
class ActiveSessionsScreen extends StatefulWidget {
  const ActiveSessionsScreen({super.key});

  @override
  State<ActiveSessionsScreen> createState() => _ActiveSessionsScreenState();
}

class _ActiveSessionsScreenState extends State<ActiveSessionsScreen> {
  List<dynamic> _sessions = [];
  bool _isLoading = true;
  String? _error;
  String? _revokingId;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    // Server pushes this whenever the account's session list changes (a login
    // elsewhere, or a device being signed out), so the list live-updates
    // without polling.
    SocketService.on(SocketEvents.sessionsUpdated, _onSessionsUpdated);
  }

  @override
  void dispose() {
    SocketService.off(SocketEvents.sessionsUpdated, _onSessionsUpdated);
    super.dispose();
  }

  void _onSessionsUpdated(dynamic _) => _loadSessions(silent: true);

  // `silent` skips the full-screen loading spinner so background refreshes
  // (triggered by the socket event) don't flash/replace the list the user is
  // looking at.
  Future<void> _loadSessions({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final sessions = await ApiService.getSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // Don't clobber the visible list with an error banner for a background
      // refresh blip — only surface errors from an explicit/initial load.
      if (!silent) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted && !silent) setState(() => _isLoading = false);
    }
  }

  Future<void> _confirmRevoke(String sessionId, String deviceName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out device?'),
        content: Text(
          'This will immediately sign out "$deviceName". Your other devices will stay signed in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _revoke(sessionId);
    }
  }

  Future<void> _revoke(String sessionId) async {
    setState(() => _revokingId = sessionId);
    try {
      await ApiService.revokeSession(sessionId);
      if (!mounted) return;
      setState(() {
        _sessions = _sessions.where((s) => s['id'] != sessionId).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That device has been logged out.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  String _formatTimestamp(String? iso) {
    if (iso == null) return 'Unknown activity';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'Active just now';
      if (diff.inMinutes < 60) return 'Active ${diff.inMinutes}m ago';
      if (diff.inHours < 24) return 'Active ${diff.inHours}h ago';
      return 'Active ${diff.inDays}d ago';
    } catch (_) {
      return 'Unknown activity';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Active Sessions')),
      body: RefreshIndicator(
        onRefresh: _loadSessions,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 60),
          Icon(Icons.error_outline_rounded, size: 48, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Center(
            child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
          ),
        ],
      );
    }
    if (_sessions.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          SizedBox(height: 60),
          Center(child: Text('No active sessions found.')),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _sessions.length,
      itemBuilder: (context, index) {
        final session = _sessions[index] as Map<String, dynamic>;
        final isCurrent = session['isCurrent'] == true;
        final platform = session['platform'] as String? ?? 'mobile';
        final deviceName = session['deviceName'] as String? ?? 'Unknown device';
        final sessionId = session['id'] as String;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isCurrent ? AppColors.primary : AppColors.cardBorder,
              width: isCurrent ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                child: Icon(
                  platform == 'web' ? Icons.laptop_mac_rounded : Icons.phone_iphone_rounded,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            deviceName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isCurrent) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'This device',
                              style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTimestamp(session['lastSeenAt'] as String?),
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (!isCurrent)
                _revokingId == sessionId
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: () => _confirmRevoke(sessionId, deviceName),
                        child: const Text('Log out'),
                      ),
            ],
          ),
        );
      },
    );
  }
}
