import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../providers.dart';
import '../../domain/entities/movie.dart';
import '../providers/movie_provider.dart';
import '../providers/category_provider.dart';
import '../../../../shared/widgets/metadata_scraper_dialog.dart';

class EditMoviePage extends ConsumerStatefulWidget {
  final Movie? movie;
  const EditMoviePage({super.key, this.movie});

  @override
  ConsumerState<EditMoviePage> createState() => _EditMoviePageState();
}

class _EditMoviePageState extends ConsumerState<EditMoviePage> {
  late TextEditingController _nameController;
  late TextEditingController _imageController;
  late TextEditingController _detailsUrlController;
  late TextEditingController _backdropUrlController;
  late TextEditingController _subtitleUrlController;
  late TextEditingController _descriptionController;
  late TextEditingController _ratingController;
  late TextEditingController _yearController;
  late TextEditingController _creditsStartTimeController;
  String? _selectedCategoryId;
  List<VideoOption> _options = [];
  bool _isScraping = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.movie?.name ?? '');
    _imageController = TextEditingController(text: widget.movie?.imagePath ?? '');
    _detailsUrlController = TextEditingController(text: widget.movie?.detailsUrl ?? '');
    _backdropUrlController = TextEditingController(text: widget.movie?.backdropUrl ?? '');
    _subtitleUrlController = TextEditingController(text: widget.movie?.subtitleUrl ?? '');
    _descriptionController = TextEditingController(text: widget.movie?.description ?? '');
    _ratingController = TextEditingController(text: widget.movie?.rating.toString() ?? '0.0');
    _yearController = TextEditingController(text: widget.movie?.year ?? '');
    _creditsStartTimeController = TextEditingController(
      text: _secondsToTime(widget.movie?.creditsStartTime),
    );
    _selectedCategoryId = widget.movie?.categoryId;
    if (widget.movie != null) {
      _loadOptions();
    }
  }

  void _loadOptions() async {
    final opts = await ref.read(movieRepositoryProvider).getVideoOptions(widget.movie!.id);
    setState(() => _options = opts);
  }

  /// Convierte segundos a HH:MM:SS (ej: 3661 → "01:01:01")
  String _secondsToTime(int? seconds) {
    if (seconds == null) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Convierte HH:MM:SS  a segundos (ej: "01:01:01" → 3661). Acepta también número puro.
  int? _parseTime(String value) {
    if (value.trim().isEmpty) return null;
    if (value.contains(':')) {
      final parts = value.trim().split(':');
      if (parts.length == 3) {
        final h = int.tryParse(parts[0]) ?? 0;
        final m = int.tryParse(parts[1]) ?? 0;
        final s = int.tryParse(parts[2]) ?? 0;
        return h * 3600 + m * 60 + s;
      }
      if (parts.length == 2) {
        final m = int.tryParse(parts[0]) ?? 0;
        final s = int.tryParse(parts[1]) ?? 0;
        return m * 60 + s;
      }
    }
    return int.tryParse(value);
  }

  void _saveMovie() async {
    if (widget.movie == null) {
      await ref.read(moviesProvider.notifier).addMovie(
        _nameController.text, 
        _imageController.text,
        categoryId: _selectedCategoryId,
        detailsUrl: _detailsUrlController.text,
        backdropUrl: _backdropUrlController.text,
        subtitleUrl: _subtitleUrlController.text,
        description: _descriptionController.text.isNotEmpty ? _descriptionController.text : null,
        rating: double.tryParse(_ratingController.text) ?? 0.0,
        year: _yearController.text.isNotEmpty ? _yearController.text : null,
        creditsStartTime: _parseTime(_creditsStartTimeController.text),
      );
    } else {
      final updatedMovie = Movie(
        id: widget.movie!.id,
        name: _nameController.text,
        imagePath: _imageController.text,
        categoryId: _selectedCategoryId,
        detailsUrl: _detailsUrlController.text,
        backdropUrl: _backdropUrlController.text,
        description: _descriptionController.text.isNotEmpty ? _descriptionController.text : null,
        views: widget.movie!.views,
        rating: double.tryParse(_ratingController.text) ?? 0.0,
        year: _yearController.text.isNotEmpty ? _yearController.text : null,
        duration: widget.movie!.duration,
        backdrop: widget.movie!.backdrop,
        subtitleUrl: _subtitleUrlController.text,
        createdAt: widget.movie!.createdAt,
        creditsStartTime: _parseTime(_creditsStartTimeController.text),
      );
      await ref.read(moviesProvider.notifier).updateMovie(updatedMovie);
    }
    if (mounted) Navigator.pop(context);
  }

  void _deleteMovie() async {
    if (widget.movie != null) {
      await ref.read(moviesProvider.notifier).deleteMovie(widget.movie!.id);
      if (mounted) Navigator.pop(context);
    }
  }

  void _showOptionModal([VideoOption? option]) {
    final resController = TextEditingController(text: option?.resolution ?? '');
    final urlController = TextEditingController(text: option?.videoUrl ?? '');
    final imgController = TextEditingController(text: option?.serverImagePath ?? '');
    String? selectedLanguage = option?.language ?? 'Latino';

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.white.withOpacity(0.1))),
            title: Text(option == null ? 'AGREGAR OPCIÓN' : 'EDITAR OPCIÓN', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDialogTextField(imgController, 'URL Imagen Servidor'),
                  _buildDialogTextField(resController, 'Resolución (ej: 1080P)'),
                  _buildDialogTextField(urlController, 'URL Video'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: ['Latino', 'Castellano', 'Inglés', 'Japonés'].contains(selectedLanguage) ? selectedLanguage : 'Latino',
                    dropdownColor: const Color(0xFF1E1E1E),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Idioma',
                      labelStyle: const TextStyle(color: Color(0xFF00A3FF), fontSize: 13, fontWeight: FontWeight.bold),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.04),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
                    ),
                    items: ['Latino', 'Castellano', 'Inglés', 'Japonés'].map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (newValue) {
                      setState(() {
                        selectedLanguage = newValue;
                      });
                    },
                  ),
                ],
              ),
            ),
            actions: [
              if (option != null)
                TextButton(
                  onPressed: () async {
                    await ref.read(movieRepositoryProvider).deleteVideoOption(option.id);
                    _loadOptions();
                    if (mounted) Navigator.pop(context);
                  },
                  child: const Text('ELIMINAR', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                ),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR', style: TextStyle(color: Colors.white54))),
              ElevatedButton(
                onPressed: () async {
                  final newOpt = VideoOption(
                    id: option?.id ?? '',
                    movieId: widget.movie!.id,
                    serverImagePath: imgController.text,
                    resolution: resController.text,
                    videoUrl: urlController.text,
                    language: selectedLanguage,
                  );
                  if (option == null) {
                    await ref.read(movieRepositoryProvider).addVideoOption(newOpt);
                  } else {
                    await ref.read(movieRepositoryProvider).updateVideoOption(newOpt);
                  }
                  _loadOptions();
                  if (mounted) Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00A3FF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDialogTextField(TextEditingController controller, String labelText) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: labelText,
          labelStyle: const TextStyle(color: Color(0xFF00A3FF), fontSize: 13, fontWeight: FontWeight.bold),
          filled: true,
          fillColor: Colors.white.withOpacity(0.04),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
        ),
      ),
    );
  }

  void _fetchMetadata() async {
    final url = _detailsUrlController.text;
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Introduce una URL de detalles primero')));
      return;
    }

    setState(() => _isScraping = true);
    
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => MetadataScraperDialog(url: url),
    );

    if (result != null) {
      setState(() {
        if (result['description'] != null) _descriptionController.text = result['description'];
        if (result['rating'] != null) _ratingController.text = result['rating'].toString();
        if (result['year'] != null) _yearController.text = result['year'].toString();
        if (result['name'] != null && _nameController.text.isEmpty) _nameController.text = result['name'];
        if (result['image'] != null && _imageController.text.isEmpty) _imageController.text = result['image'];
      });
    }
    
    setState(() => _isScraping = false);
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String labelText,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          labelText.toUpperCase(),
          style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Introduce $labelText',
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: Colors.white.withOpacity(0.04),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF00A3FF)),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: Text(
          widget.movie == null ? 'NUEVA PELÍCULA' : 'EDITAR PELÍCULA',
          style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).padding.bottom + 80),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTextField(controller: _imageController, labelText: 'URL Imagen Película (Poster)'),
            const SizedBox(height: 16),
            _buildTextField(controller: _detailsUrlController, labelText: 'URL detalles (HTML)'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isScraping ? null : _fetchMetadata,
                icon: _isScraping ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download, size: 18),
                label: const Text('EXTRAER INFO (DESCRIPCIÓN, NOTA, AÑO)'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF).withOpacity(0.1), foregroundColor: const Color(0xFF00A3FF)),
              ),
            ),
            const SizedBox(height: 24),
            _buildTextField(controller: _backdropUrlController, labelText: 'Imagen Portada (Fondo detalles)'),
            const SizedBox(height: 16),
            _buildTextField(controller: _subtitleUrlController, labelText: 'URL Subtítulos'),
            const SizedBox(height: 16),
            categoriesAsync.when(
              data: (categories) {
                final bool exists = _selectedCategoryId == null || categories.any((c) => c.id == _selectedCategoryId);
                final dropdownValue = exists ? _selectedCategoryId : null;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CATEGORÍA',
                      style: TextStyle(color: Color(0xFF00A3FF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: dropdownValue,
                      dropdownColor: const Color(0xFF1E1E1E),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.04),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF00A3FF)),
                        ),
                      ),
                      items: [
                        const DropdownMenuItem<String>(value: null, child: Text('Sin Categoría')),
                        ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
                      ],
                      onChanged: (val) => setState(() => _selectedCategoryId = val),
                    ),
                  ],
                );
              },
              loading: () => const CircularProgressIndicator(),
              error: (e, s) => Text('Error cargando categorías: $e', style: const TextStyle(color: Colors.red)),
            ),
            const SizedBox(height: 16),
            _buildTextField(controller: _nameController, labelText: 'Nombre de la Película'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildTextField(controller: _ratingController, labelText: 'Calificación (0-10)', keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 16),
                Expanded(child: _buildTextField(controller: _yearController, labelText: 'Año', keyboardType: TextInputType.number)),
              ],
            ),
            const SizedBox(height: 16),
            _buildTextField(controller: _descriptionController, labelText: 'Descripción de la Película', maxLines: 5),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _creditsStartTimeController,
              labelText: 'Inicio Créditos / Final (formato HH:MM:SS)',
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 32),
            const Text('OPCIONES DE VIDEO', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const SizedBox(height: 8),
            if (widget.movie == null)
              const Text('Guarda la película primero para agregar opciones.', style: TextStyle(color: Colors.white38))
            else ...[
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.02),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _options.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      leading: Text('OPCIÓN ${index + 1}', style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, fontSize: 10)),
                      title: Text(_options[index].resolution, style: const TextStyle(color: Colors.white)),
                      trailing: const Icon(Icons.edit, color: Colors.white38, size: 16),
                      onTap: () => _showOptionModal(_options[index]),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _showOptionModal(),
                icon: const Icon(Icons.add, color: Color(0xFF00A3FF)),
                label: const Text('NUEVA OPCIÓN', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF00A3FF)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                ),
              ),
            ],
            const SizedBox(height: 48),
            Row(
              children: [
                if (widget.movie != null) ...[
                  Expanded(
                    flex: 1,
                    child: OutlinedButton(
                      onPressed: _deleteMovie,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.redAccent),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('ELIMINAR', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  flex: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                      boxShadow: [
                        BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.3), blurRadius: 10, offset: const Offset(-2, 0)),
                        BoxShadow(color: const Color(0xFFD400FF).withOpacity(0.3), blurRadius: 10, offset: const Offset(2, 0))
                      ],
                    ),
                    child: ElevatedButton(
                      onPressed: _saveMovie,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('GUARDAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
