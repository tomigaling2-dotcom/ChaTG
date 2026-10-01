import 'package:flutter/material.dart';

void main() {
  runApp(const ChaTGApp());
}

class ChaTGApp extends StatelessWidget {
  const ChaTGApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ChaTG',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF212121),
      ),
      home: const ChaTGHome(),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isUser;

  ChatMessage({
    required this.text,
    required this.isUser,
  });
}

class ChatConversation {
  final String title;
  final List<ChatMessage> messages;

  ChatConversation({
    required this.title,
    required this.messages,
  });
}

class ChaTGHome extends StatefulWidget {
  const ChaTGHome({super.key});

  @override
  State<ChaTGHome> createState() => _ChaTGHomeState();
}

class _ChaTGHomeState extends State<ChaTGHome> {
  final TextEditingController _controller = TextEditingController();

  final List<ChatConversation> _conversations = [];

  ChatConversation? _currentConversation;

  @override
  void initState() {
    super.initState();
    _startNewChat();
  }

  void _startNewChat() {
    setState(() {
      _currentConversation = ChatConversation(
        title: 'New Chat',
        messages: [],
      );

      _conversations.insert(0, _currentConversation!);
    });

    Navigator.of(context).maybePop();
  }

  void _sendMessage() {
    final text = _controller.text.trim();

    if (text.isEmpty || _currentConversation == null) {
      return;
    }

    setState(() {
      _currentConversation!.messages.add(
        ChatMessage(
          text: text,
          isUser: true,
        ),
      );

      if (_currentConversation!.title == 'New Chat') {
        _currentConversation!.messages.isNotEmpty
            ? _currentConversation!.messages.first.text
            : 'New Chat';
      }
    });

    _controller.clear();
  }

  void _openConversation(ChatConversation conversation) {
    setState(() {
      _currentConversation = conversation;
    });

    Navigator.of(context).maybePop();
  }

  void _deleteConversation(ChatConversation conversation) {
    setState(() {
      _conversations.remove(conversation);

      if (_currentConversation == conversation) {
        _currentConversation = null;
      }
    });
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2B2B2B),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                leading: Icon(Icons.settings),
                title: Text(
                  'ChaTG Settings',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('Appearance'),
                onTap: () {
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About ChaTG'),
                onTap: () {
                  Navigator.pop(context);

                  showAboutDialog(
                    context: context,
                    applicationName: 'ChaTG',
                    applicationVersion: '1.0.0',
                    applicationLegalese:
                        'A ChatGPT-style AI chat application.',
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessage(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            child: Icon(
              message.isUser ? Icons.person : Icons.auto_awesome,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message.text,
              style: const TextStyle(
                fontSize: 16,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = _currentConversation?.messages ?? [];

    return Scaffold(
      drawer: Drawer(
        backgroundColor: const Color(0xFF171717),
        child: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'ChaTG',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _startNewChat,
                    icon: const Icon(Icons.add),
                    label: const Text('New Chat'),
                  ),
                ),
              ),

              const SizedBox(height: 15),

              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Chat History',
                    style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              Expanded(
                child: _conversations.isEmpty
                    ? const Center(
                        child: Text('No chat history'),
                      )
                    : ListView.builder(
                        itemCount: _conversations.length,
                        itemBuilder: (context, index) {
                          final conversation = _conversations[index];

                          return ListTile(
                            leading: const Icon(
                              Icons.chat_bubble_outline,
                            ),
                            title: Text(
                              conversation.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              _openConversation(conversation);
                            },
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                              ),
                              onPressed: () {
                                _deleteConversation(conversation);
                              },
                            ),
                          );
                        },
                      ),
              ),

              const Divider(),

              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: _showSettings,
              ),
            ],
          ),
        ),
      ),

      appBar: AppBar(
        title: const Text(
          'ChaTG',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'New Chat',
            onPressed: _startNewChat,
            icon: const Icon(Icons.edit_square),
          ),
        ],
      ),

      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 50,
                        ),
                        SizedBox(height: 18),
                        Text(
                          'How can I help you?',
                          style: TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 10),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      return _buildMessage(messages[index]);
                    },
                  ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                12,
                8,
                12,
                12,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Message ChaTG...',
                        filled: true,
                        fillColor: const Color(0xFF2F2F2F),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 13,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  CircleAvatar(
                    radius: 24,
                    child: IconButton(
                      onPressed: _sendMessage,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}