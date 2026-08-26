import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/message_provider.dart';
import '../../theme/app_colors.dart';

// Renders a poll message inline in the chat: question, options with live vote
// tallies, and tap-to-vote/retract interaction. Poll data itself (question,
// options, tallies) isn't part of the message payload — it's fetched lazily
// via MessageProvider.loadPoll() and kept live by the 'poll_updated' socket event.
class PollBubble extends StatefulWidget {
  final String pollId;
  final String fallbackQuestion;
  final bool isMe;

  const PollBubble({
    super.key,
    required this.pollId,
    required this.fallbackQuestion,
    required this.isMe,
  });

  @override
  State<PollBubble> createState() => _PollBubbleState();
}

class _PollBubbleState extends State<PollBubble> {
  bool _isVoting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MessageProvider>().loadPoll(widget.pollId);
    });
  }

  Future<void> _toggleOption(Map<String, dynamic> poll, String optionId, bool allowMultiple) async {
    if (_isVoting || poll['is_closed'] == true) return;

    final options = (poll['options'] as List).cast<Map<String, dynamic>>();
    final currentlyVoted = options.where((o) => o['voted_by_me'] == true).map((o) => o['id'].toString()).toSet();

    List<String> newSelection;
    if (allowMultiple) {
      newSelection = currentlyVoted.toList();
      if (currentlyVoted.contains(optionId)) {
        newSelection.remove(optionId);
      } else {
        newSelection.add(optionId);
      }
    } else {
      // Tapping the option already voted for retracts it; tapping a different
      // one replaces the single existing vote.
      newSelection = currentlyVoted.contains(optionId) ? [] : [optionId];
    }

    setState(() => _isVoting = true);
    try {
      await context.read<MessageProvider>().votePoll(widget.pollId, newSelection);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  Future<void> _confirmClosePoll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close Poll'),
        content: const Text('No one will be able to vote on this poll anymore. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close Poll', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<MessageProvider>().closePoll(widget.pollId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  void _showVoters(List<dynamic>? voterUsernames) {
    if (voterUsernames == null || voterUsernames.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Voted for this option'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: voterUsernames.map((u) => ListTile(title: Text(u.toString()))).toList(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.isMe;
    final fgColor = isMe ? Colors.white : AppColors.textPrimary;
    final secondaryColor = isMe ? Colors.white70 : AppColors.textSecondary;
    final poll = context.watch<MessageProvider>().pollData(widget.pollId);

    if (poll == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: secondaryColor),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.fallbackQuestion,
              style: TextStyle(color: fgColor, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    }

    final options = (poll['options'] as List).cast<Map<String, dynamic>>();
    final isAnonymous = poll['is_anonymous'] == true;
    final allowMultiple = poll['allow_multiple_answers'] == true;
    final isClosed = poll['is_closed'] == true;
    final totalVoters = (poll['total_voters'] as num?)?.toInt() ?? 0;
    final isCreator = context.read<MessageProvider>().currentUserId == poll['creator_id'];

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.poll_outlined, size: 16, color: fgColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  poll['question']?.toString() ?? widget.fallbackQuestion,
                  style: TextStyle(color: fgColor, fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (isAnonymous) 'Anonymous' else 'Public votes',
              if (allowMultiple) 'Multiple choice',
              if (isClosed) 'Closed',
            ].join(' · '),
            style: TextStyle(color: secondaryColor, fontSize: 11),
          ),
          const SizedBox(height: 8),
          ...options.map((option) {
            final optionId = option['id'].toString();
            final voteCount = (option['vote_count'] as num?)?.toInt() ?? 0;
            final votedByMe = option['voted_by_me'] == true;
            final percent = totalVoters > 0 ? (voteCount / totalVoters * 100).round() : 0;
            final voterUsernames = option['voter_usernames'] as List<dynamic>?;

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: GestureDetector(
                onTap: isClosed ? null : () => _toggleOption(poll, optionId, allowMultiple),
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: (isMe ? Colors.white : AppColors.primary).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: votedByMe
                            ? Border.all(color: isMe ? Colors.white : AppColors.primary, width: 1.2)
                            : null,
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: (percent / 100).clamp(0.0, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: (isMe ? Colors.white : AppColors.primary).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const SizedBox(height: 34),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            votedByMe ? Icons.check_circle : Icons.circle_outlined,
                            size: 16,
                            color: fgColor,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              option['option_text']?.toString() ?? '',
                              style: TextStyle(color: fgColor, fontSize: 14),
                            ),
                          ),
                          GestureDetector(
                            onTap: !isAnonymous && voteCount > 0 ? () => _showVoters(voterUsernames) : null,
                            child: Text(
                              '$voteCount',
                              style: TextStyle(
                                color: secondaryColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                decoration: !isAnonymous && voteCount > 0 ? TextDecoration.underline : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          Text(
            '$totalVoters vote${totalVoters == 1 ? '' : 's'}',
            style: TextStyle(color: secondaryColor, fontSize: 11),
          ),
          if (isCreator && !isClosed)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _confirmClosePoll,
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 28)),
                child: Text(
                  'Close Poll',
                  style: TextStyle(color: isMe ? Colors.white : AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
