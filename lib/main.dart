import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_service.dart';

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
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10A37F),
          brightness: Brightness.dark,
        ),
      ),
      home: const ChaTGHome(),
    );
  }
}

enum MessageType { text, image }

class ChatMessage {
  final String role;
  final String text;
  final MessageType type;
  final Uint8List? imageBytes;
  final String? mimeType;
  final List<AiSource> sources;

  ChatMessage.text({
    required this.role,
    required this.text,
    this.sources = const [],
  })  : type = MessageType.text,
        imageBytes = null,
        mimeType = null;

  ChatMessage.image({
    required this.role,
    required this.imageBytes,
    required this.mimeType,
    this.text = '',
  })  : type = MessageType.image,
        sources = const [];
}

class ChatConversation {
  String title;
  final List<ChatMessage> messages;

  ChatConversation({
    this.title = 'New chat',
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];
}

class ChaTGHome extends StatefulWidget {
  const ChaTGHome({super.key});

  @override
  State<ChaTGHome> createState() => _ChaTGHomeState();
}

class _ChaTGHomeState extends State<ChaTGHome> {
  final AiService _ai = AiService();
  final ImagePicker _picker = ImagePicker();
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<ChatConversation> _chats = [];

  bool _sending = false;
  bool _imageMode = false;
  bool _editMode = false;
  bool _speechAvailable = false;
  bool _isListening = false;
  bool _ttsSpeaking = false;
  final bool _webSearch = false;

  String _anonymousUserId = '';

  Uint8List? _pendingImageBytes;
  String? _pendingImageMime;

  String? _attachedFileName;
  String? _attachedFileText;
  Uint8List? _attachedFileBytes;
  String? _attachedFileMime;
  bool _attachedFileIsText = false;

  String _voiceBaseText = '';

  ChatConversation get _chat => _chats.first;

  @override
  void initState() {
    super.initState();
    _newChat();
    _initAnonymousUserId();
    _initVoiceAndTts();
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initAnonymousUserId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('chatg_anonymous_user_id');

    if (id == null || id.isEmpty) {
      id =
          '${DateTime.now().microsecondsSinceEpoch}_${Object().hashCode}';
      await prefs.setString(
        'chatg_anonymous_user_id',
        id,
      );
    }

    if (mounted) {
      setState(() {
        _anonymousUserId = id!;
      });
    } else {
      _anonymousUserId = id;
    }
  }
  Future<void> _initVoiceAndTts() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;

          if (status == 'done' || status == 'notListening') {
            setState(() {
              _isListening = false;
            });
          }
        },
        onError: (error) {
          if (!mounted) return;

          setState(() {
            _isListening = false;
          });
        },
      );

      if (mounted) {
        setState(() {
          _speechAvailable = available;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _speechAvailable = false;
        });
      }
    }

    try {
      await _tts.setLanguage('en-IN');
      await _tts.setSpeechRate(0.48);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setStartHandler(() {
        if (!mounted) return;
        setState(() {
          _ttsSpeaking = true;
        });
      });

      _tts.setCompletionHandler(() {
        if (!mounted) return;
        setState(() {
          _ttsSpeaking = false;
        });
      });

      _tts.setCancelHandler(() {
        if (!mounted) return;
        setState(() {
          _ttsSpeaking = false;
        });
      });

      _tts.setErrorHandler((_) {
        if (!mounted) return;
        setState(() {
          _ttsSpeaking = false;
        });
      });
    } catch (_) {
      // Text-to-speech is optional; the chat continues to work without it.
    }
  }

  void _newChat() {
    setState(() {
      _chats.insert(0, ChatConversation());
      _imageMode = false;
      _editMode = false;
      _pendingImageBytes = null;
      _pendingImageMime = null;
      _clearAttachment();
      _controller.clear();
    });
  }
void _renameChat(ChatConversation chat) {
    final controller = TextEditingController(text: chat.title);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
              hintText: 'Chat name',
            ),
            onSubmitted: (_) {
              final title = controller.text.trim();

              if (title.isNotEmpty) {
                setState(() {
                  chat.title = title;
                });
              }

              Navigator.pop(context);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final title = controller.text.trim();

                if (title.isNotEmpty) {
                  setState(() {
                    chat.title = title;
                  });
                }

                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ).then((_) => controller.dispose());
  }
  void _clearAttachment() {
    _attachedFileName = null;
    _attachedFileText = null;
    _attachedFileBytes = null;
    _attachedFileMime = null;
    _attachedFileIsText = false;
  }

  List<Map<String, String>> _history() {
    return _chat.messages
        .where((m) => m.type == MessageType.text)
        .map(
          (m) => {
            'role': m.role,
            'content': m.text,
          },
        )
        .toList();
  }

  bool _looksLikeImageEditRequest(String text) {
    final q = text.toLowerCase();

    const editPhrases = [
      'edit',
      'editing',
      'change',
      'remove background',
      'background remove',
      'replace background',
      'add background',
      'filter',
      'retouch',
      'enhance',
      'enhancement',
      'brightness',
      'contrast',
      'crop',
      'blur',
      'recolor',
      'colour',
      'color',
      'erase',
      'remove object',
      'remove person',
      'remove people',
      'make the background',
      'change the background',
    ];

    return editPhrases.any(q.contains);
  }

  Future<void> _editAttachedImage(String prompt) async {
    final imageBytes = _attachedFileBytes;
    final mime = _attachedFileMime;

    if (imageBytes == null ||
        mime == null ||
        !mime.startsWith('image/')) {
      return;
    }

    setState(() {
      _sending = true;
      _controller.clear();

      _chat.messages.add(
        ChatMessage.image(
          role: 'user',
          imageBytes: imageBytes,
          mimeType: mime,
        ),
      );

      _clearAttachment();
    });

    _scrollToBottom();

    try {
      final result = await _ai.editImage(
        imageBytes: imageBytes,
        mimeType: mime,
        prompt: prompt,
        userId: _anonymousUserId,
      );

      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.image(
            role: 'assistant',
            imageBytes: result.bytes,
            mimeType: result.mimeType,
          ),
        );
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.text(
            role: 'assistant',
            text: 'Image editing failed.\n\n',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });

        _scrollToBottom();
      }
    }
  }
  Future<void> _send() async {
    if (_sending) return;

    final text = _controller.text.trim();

    if (_editMode && _pendingImageBytes != null) {
      if (text.isEmpty) return;
      await _editPendingImage(text);
      return;
    }

    if (_imageMode) {
      if (text.isEmpty) return;
      await _generateImage(text);
      return;
    }
    if (_attachedFileBytes != null &&
        _attachedFileMime != null &&
        _attachedFileMime!.startsWith('image/')
   &&
        text.isNotEmpty &&
        _looksLikeImageEditRequest(text)) {
      await _editAttachedImage(text);
      return;
    }
    if (text.isEmpty && _attachedFileName == null) return;

    await _sendChat(text);
  }

  Future<void> _sendChat(String text) async {
    final chat = _chat;
    final fileName = _attachedFileName;
    final fileText = _attachedFileText;
    final fileBytes = _attachedFileBytes;
    final fileMime = _attachedFileMime;
    final fileIsText = _attachedFileIsText;

    String messageForAi = text;

    if (fileName != null && fileIsText && fileText != null) {
      messageForAi = '''
User message:
$text

Attached file: $fileName

File content:
$fileText
'''.trim();
    }

    final encodedFile = fileBytes == null ? null : base64Encode(fileBytes);

    final visibleText = fileName == null
        ? text
        : text.isEmpty
            ? '?? $fileName'
            : '$text\n\n?? $fileName';

    final historyBeforeCurrentMessage = _history();

    setState(() {
      chat.messages.add(
        ChatMessage.text(
          role: 'user',
          text: visibleText,
        ),
      );

      if (chat.title == 'New chat') {
        final titleSource = text.isEmpty ? fileName! : text;
        chat.title = titleSource.length > 30
            ? '${titleSource.substring(0, 30)}...'
            : titleSource;
      }

      _controller.clear();
      _clearAttachment();
      _sending = true;
    });

    _scrollToBottom();

    try {
      final result = await _ai.chat(
        message: messageForAi,
        history: historyBeforeCurrentMessage,
        fileBase64: encodedFile,
        fileMimeType: fileMime,
        fileName: fileName,
        useWebSearch: _webSearch,
      );

      if (!mounted) return;

      setState(() {
        chat.messages.add(
          ChatMessage.text(
            role: 'assistant',
            text: result.reply,
            sources: result.sources,
          ),
        );
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        chat.messages.add(
          ChatMessage.text(
            role: 'assistant',
            text: 'Sorry, something went wrong.\n\n$e',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });

        _scrollToBottom();
      }
    }
  }

  Future<void> _generateImage(String prompt) async {
    if (_sending) return;

    setState(() {
      _sending = true;
      _controller.clear();

      _chat.messages.add(
        ChatMessage.text(
          role: 'user',
          text: prompt,
        ),
      );
    });

    _scrollToBottom();

    try {
      final result = await _ai.generateImage(prompt, _anonymousUserId);

      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.image(
            role: 'assistant',
            imageBytes: result.bytes,
            mimeType: result.mimeType,
          ),
        );
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.text(
            role: 'assistant',
            text: 'Image generation failed.\n\n$e',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _imageMode = false;
        });

        _scrollToBottom();
      }
    }
  }

  Future<void> _chooseEditImage() async {
    if (_sending) return;

    final file = await _picker.pickImage(
      source: ImageSource.gallery,
    );

    if (file == null) return;

    final bytes = await file.readAsBytes();
    final mime = _mimeFromName(file.name);

    if (!mounted) return;

    setState(() {
      _pendingImageBytes = bytes;
      _pendingImageMime = mime;
      _editMode = true;
      _imageMode = false;
    });

    _controller.clear();
  }

  Future<void> _takePhotoForEdit() async {
    if (_sending) return;

    final file = await _picker.pickImage(
      source: ImageSource.camera,
    );

    if (file == null) return;

    final bytes = await file.readAsBytes();
    final mime = _mimeFromName(file.name);

    if (!mounted) return;

    setState(() {
      _pendingImageBytes = bytes;
      _pendingImageMime = mime;
      _editMode = true;
      _imageMode = false;
    });

    _controller.clear();
  }

  Future<void> _editPendingImage(String prompt) async {
    final imageBytes = _pendingImageBytes;
    final mime = _pendingImageMime;

    if (imageBytes == null || mime == null) return;

    setState(() {
      _sending = true;
      _controller.clear();

      _chat.messages.add(
        ChatMessage.image(
          role: 'user',
          imageBytes: imageBytes,
          mimeType: mime,
        ),
      );

      _pendingImageBytes = null;
      _pendingImageMime = null;
    });

    _scrollToBottom();

    try {
      final result = await _ai.editImage(
        imageBytes: imageBytes,
        mimeType: mime,
        prompt: prompt,
        userId: _anonymousUserId,
      );

      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.image(
            role: 'assistant',
            imageBytes: result.bytes,
            mimeType: result.mimeType,
          ),
        );
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.text(
            role: 'assistant',
            text: 'Image editing failed.\n\n$e',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _editMode = false;
        });

        _scrollToBottom();
      }
    }
  }

  Future<void> _analyzeImage() async {
    if (_sending) return;

    final file = await _picker.pickImage(
      source: ImageSource.gallery,
    );

    if (file == null) return;

    final bytes = await file.readAsBytes();
    final mime = _mimeFromName(file.name);

    if (!mounted) return;

    setState(() {
      _sending = true;

      _chat.messages.add(
        ChatMessage.image(
          role: 'user',
          imageBytes: bytes,
          mimeType: mime,
        ),
      );
    });

    _scrollToBottom();

    try {
      final result = await _ai.analyzeImage(
        imageBytes: bytes,
        mimeType: mime,
      );

      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.text(
            role: 'assistant',
            text: result,
          ),
        );
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _chat.messages.add(
          ChatMessage.text(
            role: 'assistant',
            text: 'Image analysis failed.\n\n$e',
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });

        _scrollToBottom();
      }
    }
  }

  Future<void> _pickFile() async {
    if (_sending) return;

    try {
      final file = await FilePicker.pickFile();

      if (file == null) return;

      final fileName = file.name;
      final extension = (file.extension ?? '').toLowerCase();
      final fileBytes = await file.readAsBytes();
      final fileLength = fileBytes.length;

      if (fileLength > 5 * 1024 * 1024) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'For now, attachments must be 5 MB or smaller.',
            ),
          ),
        );
        return;
      }

      final textExtensions = <String>{
        'txt',
        'md',
        'csv',
        'json',
        'xml',
        'html',
        'htm',
        'css',
        'dart',
        'js',
        'ts',
        'py',
        'java',
        'c',
        'cpp',
        'h',
        'hpp',
        'log',
        'yaml',
        'yml',
        'sql',
        'sh',
        'bat',
      };

      String? parsedText;
      Uint8List? binaryBytes;
      String? mimeType;

      if (textExtensions.contains(extension)) {
        parsedText = utf8.decode(
          fileBytes,
          allowMalformed: true,
        );
      } else if (extension == 'pdf') {
        binaryBytes = fileBytes;
        mimeType = 'application/pdf';
      } else if ({'jpg','jpeg','png','webp','gif','bmp'}.contains(extension)) {
        binaryBytes = fileBytes;
        mimeType = 'image/';
        if (extension == 'jpg' || extension == 'jpeg') mimeType = 'image/jpeg';
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '$fileName attached. This version can directly analyze PDF and plain-text files.',
              ),
            ),
          );
        }
      }

      if (!mounted) return;

      setState(() {
        _attachedFileName = fileName;
        _attachedFileText = parsedText;
        _attachedFileBytes = binaryBytes;
        _attachedFileMime = mimeType;
        _attachedFileIsText = parsedText != null;
      });

      if (extension == 'pdf') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'PDF attached. ChaTG will send the PDF to the AI for reading.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not attach file: $e'),
        ),
      );
    }
  }

  void _removePendingImage() {
    setState(() {
      _pendingImageBytes = null;
      _pendingImageMime = null;
      _editMode = false;
    });
  }

  void _removeAttachment() {
    setState(() {
      _clearAttachment();
    });
  }

  Future<void> _toggleVoice() async {
    if (_sending) return;

    if (!_speechAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Voice recognition is not available here. In Chrome, allow microphone permission and try again.',
          ),
        ),
      );
      return;
    }

    if (_isListening) {
      await _speech.stop();

      if (!mounted) return;

      setState(() {
        _isListening = false;
      });
      return;
    }

    _voiceBaseText = _controller.text.trim();

    setState(() {
      _isListening = true;
    });

    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          autoPunctuation: true,
        ),
      );
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _isListening = false;
      });
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final spoken = result.recognizedWords.trim();

    if (spoken.isEmpty) return;

    final combined = _voiceBaseText.isEmpty
        ? spoken
        : '$_voiceBaseText $spoken';

    _controller.value = TextEditingValue(
      text: combined,
      selection: TextSelection.collapsed(
        offset: combined.length,
      ),
    );

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _speakReply(String text) async {
    final cleaned = _cleanForSpeech(text);

    if (cleaned.isEmpty) return;

    try {
      await _tts.stop();
      await _tts.speak(cleaned);
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Voice playback is not available on this device/browser.',
          ),
        ),
      );
    }
  }

  Future<void> _stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Ignore TTS stop errors.
    }

    if (!mounted) return;

    setState(() {
      _ttsSpeaking = false;
    });
  }

  String _cleanForSpeech(String text) {
    return text
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' code block omitted ')
        .replaceAll(RegExp(r'\*\*(.*?)\*\*'), r'\1')
        .replaceAll(RegExp(r'__(.*?)__'), r'\1')
        .replaceAll(RegExp(r'\*(.*?)\*'), r'\1')
        .replaceAll(RegExp(r'_(.*?)_'), r'\1')
        .replaceAll(RegExp(r'#+\s*'), '')
        .replaceAll(RegExp(r'\[(.*?)\]\([^)]*\)'), r'\1')
        .replaceAll('`', '')
        .trim();
  }

  String _mimeFromName(String name) {
    final lower = name.toLowerCase();

    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';

    return 'image/jpeg';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openSource(AiSource source) async {
    final uri = Uri.tryParse(source.url.trim());

    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https')) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This source link is not valid.'),
        ),
      );
      return;
    }

    try {
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      );

      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open this source.'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open this source.'),
        ),
      );
    }
  }

  Widget _sourceCard(AiSource source) {
    final displayTitle = source.title.trim().isEmpty
        ? source.url
        : source.title.trim();

    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 4),
      child: Material(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openSource(source),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.language,
                    size: 18,
                    color: Color(0xFF10A37F),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFE8E8E8),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        source.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF8FCFC0),
                          fontSize: 11,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                      if (source.snippet != null &&
                          source.snippet!.trim().isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          source.snippet!.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFAAAAAA),
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                const Icon(
                  Icons.open_in_new,
                  size: 16,
                  color: Color(0xFF8E8E8E),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sourceSection(List<AiSource> sources) {
    if (sources.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.travel_explore,
                  size: 17,
                  color: Color(0xFF10A37F),
                ),
                SizedBox(width: 7),
                Text(
                  'Sources',
                  style: TextStyle(
                    color: Color(0xFFD8D8D8),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          ...sources.map(_sourceCard),
        ],
      ),
    );
  }

  Widget _message(ChatMessage message) {
    final user = message.role == 'user';

    return Padding(
      padding: EdgeInsets.fromLTRB(
        user ? 70 : 20,
        10,
        user ? 20 : 70,
        10,
      ),
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: user
                        ? const Color(0xFF2563EB)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: message.type == MessageType.image
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            message.imageBytes!,
                            width: 500,
                            fit: BoxFit.contain,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MarkdownBody(
                             data: message.text,
                             selectable: true,
                             softLineBreak: true,
                             onTapLink: (text, href, title) {
                              if (href != null && href.isNotEmpty) {
                                _openSource(
                                 AiSource(
                                  title: text.isNotEmpty ? text : href,
                                  url: href,
                                 ),
                                );
                               }
                              },
                              styleSheet: MarkdownStyleSheet(
                                p: const TextStyle(
                                  color: Color(0xFFE8E8E8),
                                  fontSize: 16,
                                  height: 1.55,
                                ),
                                strong: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                                em: const TextStyle(
                                  color: Color(0xFFE8E8E8),
                                ),
                                code: const TextStyle(
                                  color: Colors.white,
                                  fontFamily: 'monospace',
                                  backgroundColor: Color(0xFF151515),
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: const Color(0xFF151515),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                blockquote: const TextStyle(
                                  color: Colors.white70,
                                ),
                                listBullet: const TextStyle(
                                  color: Color(0xFFE8E8E8),
                                ),
                              ),
                            ),
                            if (!user) _sourceSection(message.sources),
                            if (!user)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Read aloud',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () =>
                                        _speakReply(message.text),
                                    icon: Icon(
                                      _ttsSpeaking
                                          ? Icons.volume_up
                                          : Icons.volume_up_outlined,
                                      size: 19,
                                      color: const Color(0xFF9E9E9E),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Stop voice',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: _ttsSpeaking
                                        ? _stopSpeaking
                                        : null,
                                    icon: const Icon(
                                      Icons.stop_circle_outlined,
                                      size: 19,
                                      color: Color(0xFF9E9E9E),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

void _openSettings() {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF171717),
    builder: (context) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.settings_outlined),
              title: Text(
                'Settings',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About ChaTG'),
              subtitle: const Text('ChaTG AI Assistant'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Clear chat history'),
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  _chats.clear();
                  _chats.add(ChatConversation());
                  _imageMode = false;
                  _editMode = false;
                  _pendingImageBytes = null;
                  _pendingImageMime = null;
                  _clearAttachment();
                  _controller.clear();
                });
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      );
    },
  );
}
  Widget _sidebar() {
    return Container(
      width: 270,
      color: const Color(0xFF171717),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sending ? null : _newChat,
                  icon: const Icon(Icons.add),
                  label: const Text('New chat'),
                ),
              ),
            ),
            const Divider(color: Color(0xFF303030)),
            Expanded(
              child: ListView.builder(
                itemCount: _chats.length,
                itemBuilder: (context, index) {
                  final chat = _chats[index];

                  return ListTile(
                    leading: const Icon(
                      Icons.chat_bubble_outline,
                      size: 19,
                    ),
                    title: GestureDetector(
                     onLongPress: _sending
                     ? null
                    : () => _renameChat(chat),
                child: Text(
                 chat.title,
                 maxLines: 1,
                 overflow: TextOverflow.ellipsis,
                ),
              ),
                    trailing: IconButton(
                      tooltip: 'Delete chat',
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 19,
                      ),
                      onPressed: _sending
                          ? null
                          : () {
                              setState(() {
                                _chats.removeAt(index);

                                if (_chats.isEmpty) {
                                  _chats.add(ChatConversation());
                                }
                              });
                            },
                    ),
                    onTap: () {
                      setState(() {
                        final item = _chats.removeAt(index);
                        _chats.insert(0, item);
                      });
                    },
                  );
                },
              ),
            ),
            Column(
  children: [
    ListTile(
      leading: const Icon(Icons.settings_outlined),
      title: const Text('Settings'),
      onTap: _openSettings,
    ),
    const Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'ChaTG',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
    ),
  ],
),
          ],
        ),
      ),
    );
  }

  Widget _pendingImagePreview() {
    if (_pendingImageBytes == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  _pendingImageBytes!,
                  width: 90,
                  height: 90,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                right: 3,
                top: 3,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.72),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _removePendingImage,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF242424),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: Color(0xFF10A37F),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Image ready to edit. Describe the changes below.',
                      style: TextStyle(
                        color: Color(0xFFD8D8D8),
                        fontSize: 13,
                      ),
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

  Widget _attachedFilePreview() {
    if (_attachedFileName == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF242424),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.insert_drive_file_outlined,
              color: Color(0xFF10A37F),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _attachedFileName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFE5E5E5),
                ),
              ),
            ),
            if (_attachedFileIsText)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text(
                  'TEXT',
                  style: TextStyle(
                    color: Color(0xFF10A37F),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Remove file',
              onPressed: _removeAttachment,
              icon: const Icon(
                Icons.close,
                size: 19,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadingIndicator() {
    String label = 'Thinking...';

    if (_editMode) {
      label = 'Editing image...';
    } else if (_imageMode) {
      label = 'Generating image...';
    } else if (_isListening) {
      label = 'Listening...';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
      child: Row(
        children: [
          const SizedBox(width: 4),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFBDBDBD),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _input() {
    final hasPendingImage = _pendingImageBytes != null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF2F2F2F),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: _controller.text.isNotEmpty ||
                        hasPendingImage ||
                        _attachedFileName != null
                    ? const Color(0xFF555555)
                    : const Color(0xFF444444),
              ),
            ),
            child: Column(
              children: [
                if (hasPendingImage) _pendingImagePreview(),
                if (_attachedFileName != null) _attachedFilePreview(),

                if (_imageMode || _editMode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 10, 0),
                    child: Row(
                      children: [
                        Icon(
                          _editMode
                              ? Icons.edit_outlined
                              : Icons.image_outlined,
                          size: 18,
                          color: const Color(0xFF10A37F),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _editMode
                                ? 'Edit image'
                                : 'Image generation mode',
                            style: const TextStyle(
                              color: Color(0xFFE0E0E0),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: _sending
                              ? null
                              : () {
                                  setState(() {
                                    _imageMode = false;
                                    _editMode = false;
                                    _pendingImageBytes = null;
                                    _pendingImageMime = null;
                                  });
                                },
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ),
                  ),

                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Add',
                      icon: const Icon(
                        Icons.add_circle_outline,
                        color: Color(0xFFBDBDBD),
                      ),
                      enabled: !_sending,
                      onSelected: (value) {
                        if (value == 'generate') {
                          setState(() {
                            _imageMode = true;
                            _editMode = false;
                            _pendingImageBytes = null;
                            _pendingImageMime = null;
                          });
                        } else if (value == 'edit') {
                          _chooseEditImage();
                        } else if (value == 'camera') {
                          _takePhotoForEdit();
                        } else if (value == 'analyze') {
                          _analyzeImage();
                        } else if (value == 'file') {
                          _pickFile();
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'file',
                          child: Row(
                            children: [
                              Icon(Icons.attach_file),
                              SizedBox(width: 10),
                              Text('Attach file'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'camera',
                          child: Row(
                            children: [
                              Icon(Icons.camera_alt_outlined),
                              SizedBox(width: 10),
                              Text('Camera'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit_outlined),
                              SizedBox(width: 10),
                              Text('Edit image'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'analyze',
                          child: Row(
                            children: [
                              Icon(Icons.visibility_outlined),
                              SizedBox(width: 10),
                              Text('Analyze image'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'generate',
                          child: Row(
                            children: [
                              Icon(Icons.image_outlined),
                              SizedBox(width: 10),
                              Text('Generate image'),
                            ],
                          ),
                        ),
                      ],
                    ),

                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: !_sending,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        style: const TextStyle(
                          color: Color(0xFFF1F1F1),
                          fontSize: 16,
                          height: 1.45,
                        ),
                        cursorColor: const Color(0xFF10A37F),
                        onChanged: (_) {
                          setState(() {});
                        },
                        decoration: InputDecoration(
                          hintText: _editMode
                              ? 'Describe what you want to change...'
                              : _imageMode
                                  ? 'Describe the image...'
                                  : 'Message ChaTG...',
                          hintStyle: const TextStyle(
                            color: Color(0xFF8E8E8E),
                            fontSize: 16,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                             borderRadius: BorderRadius.circular(24),
                             borderSide: const BorderSide(
                             color: Color(0xFF404040),
                             width: 1,
                           ),
                          ),
                          disabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          fillColor: const Color(0xFF2F2F2F),
                          filled: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                         ),
                       ),
                     ),

                    IconButton(
                      tooltip: _isListening ? 'Stop listening' : 'Voice input',
                      onPressed: _sending ? null : _toggleVoice,
                      color: _isListening
                          ? const Color(0xFFE5484D)
                          : const Color(0xFFBDBDBD),
                      icon: Icon(
                        _isListening
                            ? Icons.mic
                            : Icons.mic_none_outlined,
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.only(right: 6, bottom: 6),
                      child: Material(
                        color: _sending ||
                                (_controller.text.trim().isEmpty &&
                                    _attachedFileName == null)
                            ? const Color(0xFF555555)
                            : const Color(0xFF10A37F),
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: _sending ? 'Working...' : 'Send',
                          onPressed: _sending ||
                                  (_controller.text.trim().isEmpty &&
                                      _attachedFileName == null)
                              ? null
                              : _send,
                          icon: _sending
                              ? const SizedBox(
                                  width: 19,
                                  height: 19,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.arrow_upward,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      drawer: wide
          ? null
          : Drawer(
              backgroundColor: const Color(0xFF171717),
              child: _sidebar(),
            ),
      appBar: AppBar(
        backgroundColor: const Color(0xFF212121),
        title: const Text(
          'ChaTG',
          style: TextStyle(
            color: Color(0xFFF1F1F1),
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: wide
            ? null
            : Builder(
                builder: (context) {
                  return IconButton(
                    onPressed: () {
                      Scaffold.of(context).openDrawer();
                    },
                    icon: const Icon(Icons.menu),
                  );
                },
              ),
        actions: [
          IconButton(
            tooltip: 'New chat',
            onPressed: _sending ? null : _newChat,
            icon: const Icon(Icons.edit_square),
          ),
        ],
      ),
      body: Row(
        children: [
          if (wide) _sidebar(),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: _chat.messages.isEmpty
                      ? const Center(
                          child: Text(
                            'How can I help you today?',
                            style: TextStyle(
                              color: Color(0xFFE8E8E8),
                              fontSize: 27,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.only(
                            top: 18,
                            bottom: 18,
                          ),
                          itemCount: _chat.messages.length,
                          itemBuilder: (context, index) {
                            return _message(_chat.messages[index]);
                          },
                        ),
                ),
                if (_sending) _loadingIndicator(),
                Center(child: _input()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}














