import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../providers.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/series_option.dart';
import '../providers/series_provider.dart';
import '../providers/series_category_provider.dart';
import 'admin_seasons_episodes_page.dart';
import '../../../../shared/widgets/metadata_scraper_dialog.dart';
import '../../../../core/services/tmdb_service.dart';

class EditSeriesPage extends ConsumerStatefulWidget {
  final Series? series;
  const EditSeriesPage({super.key, this.series});

  @override
  ConsumerState<EditSeriesPage> createState() => _EditSeriesPageState();
}

class _EditSeriesPageState extends ConsumerState<EditSeriesPage> {
  late TextEditingController _nameController;
  late TextEditingController _imageController;
  late TextEditingController _detailsUrlController;
  late TextEditingController _backdropUrlController;
  late TextEditingController _descriptionController;
  late TextEditingController _ratingController;
  late TextEditingController _yearController;
  late TextEditingController _tmdbIdController;
  late TextEditingController _imdbIdController;
  String? _selectedCategoryId;
  List<SeriesOption> _options = [];
  bool _isScraping = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.series?.name ?? '');
    _imageController = TextEditingController(text: widget.series?.imagePath ?? '');
    _detailsUrlController = TextEditingController(text: widget.series?.detailsUrl ?? '');
    _backdropUrlController = TextEditingController(text: widget.series?.backdropUrl ?? '');
    _descriptionController = TextEditingController(text: widget.series?.description ?? '');
    _ratingController = TextEditingController(text: widget.series?.rating.toString() ?? '0.0');
    _yearController = TextEditingController(text: widget.series?.year ?? '');
    _tmdbIdController = TextEditingController(text: widget.series?.tmdbId ?? '');
    _imdbIdController = TextEditingController(text: widget.series?.imdbId ?? '');
    _selectedCategoryId = widget.series?.categoryId;
    if (widget.series != null) {
      _loadOptions();
    }
  }

  void _loadOptions() async {
    final opts = await ref.read(seriesRepositoryProvider).getSeriesOptions(widget.series!.id);
    setState(() => _options = opts);
  }

  void _saveSeries() async {
    if (widget.series == null) {
      final newSeries = Series(
        id: const Uuid().v4(),
        name: _nameController.text,
        imagePath: _imageController.text,
        categoryId: _selectedCategoryId,
        detailsUrl: _detailsUrlController.text,
        backdropUrl: _backdropUrlController.text,
        description: _descriptionController.text.isNotEmpty ? _descriptionController.text : null,
        rating: double.tryParse(_ratingController.text) ?? 0.0,
        year: _yearController.text.isNotEmpty ? _yearController.text : null,
        createdAt: DateTime.now(),
        tmdbId: _tmdbIdController.text.isNotEmpty ? _tmdbIdController.text : null,
        imdbId: _imdbIdController.text.isNotEmpty ? _imdbIdController.text : null,
      );
      await ref.read(seriesListProvider.notifier).addSeries(newSeries);
    } else {
      final updatedSeries = Series(
        id: widget.series!.id,
        name: _nameController.text,
        imagePath: _imageController.text,
        categoryId: _selectedCategoryId,
        detailsUrl: _detailsUrlController.text,
        backdropUrl: _backdropUrlController.text,
        description: _descriptionController.text.isNotEmpty ? _descriptionController.text : null,
        views: widget.series!.views,
        rating: double.tryParse(_ratingController.text) ?? 0.0,
        year: _yearController.text.isNotEmpty ? _yearController.text : null,
        backdrop: widget.series!.backdrop,
        createdAt: widget.series!.createdAt,
        tmdbId: _tmdbIdController.text.isNotEmpty ? _tmdbIdController.text : null,
        imdbId: _imdbIdController.text.isNotEmpty ? _imdbIdController.text : null,
      );
      await ref.read(seriesListProvider.notifier).updateSeries(updatedSeries);
    }
    if (mounted) Navigator.pop(context);
  }

  void _deleteSeries() async {
    if (widget.series != null) {
      await ref.read(seriesListProvider.notifier).deleteSeries(widget.series!.id);
      if (mounted) Navigator.pop(context);
    }
  }

  void _showOptionModal([SeriesOption? option]) {
    final resController = TextEditingController(text: option?.resolution ?? '720P');
    final urlController = TextEditingController(text: option?.videoUrl ?? '');
    final imgController = TextEditingController(text: option?.serverImagePath ?? '');
    String? selectedLanguage = option?.language ?? 'Latino';
    int selectedAlgorithm = option?.extractionAlgorithm ?? 1;

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
                  _buildTextField(controller: resController, labelText: 'Resolución (ej: 1080p, Auto)'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    dropdownColor: const Color(0xFF2C2C2C),
                    value: selectedLanguage,
                    decoration: InputDecoration(
                      labelText: 'Idioma',
                      labelStyle: const TextStyle(color: Color(0xFF00A3FF), fontSize: 13, fontWeight: FontWeight.bold),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.04),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'Latino', child: Text('Latino', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 'Castellano', child: Text('Castellano', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 'Inglés', child: Text('Inglés', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 'Japonés', child: Text('Japonés', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 'Subtitulado', child: Text('Subtitulado', style: TextStyle(color: Colors.white))),
                    ],
                    onChanged: (val) {
                      setState(() {
                        selectedLanguage = val;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    isExpanded: true,
                    dropdownColor: const Color(0xFF2C2C2C),
                    value: [1, 2, 3].contains(selectedAlgorithm) ? selectedAlgorithm : 1,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Algoritmo de Extracción',
                      labelStyle: const TextStyle(color: Color(0xFF00A3FF), fontSize: 13, fontWeight: FontWeight.bold),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.04),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
                    ),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Algoritmo 1: DOM + Calidades', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 2, child: Text('Algoritmo 2: Clicks Nativos', style: TextStyle(color: Colors.white))),
                      DropdownMenuItem(value: 3, child: Text('Algoritmo 3: Enlace Mágico', style: TextStyle(color: Colors.white))),
                    ],
                    onChanged: (val) {
                      setState(() {
                        selectedAlgorithm = val ?? 1;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(controller: urlController, labelText: 'URL de Extracción (o video directo)'),
                  const SizedBox(height: 12),
                  _buildTextField(controller: imgController, labelText: 'URL de la Imagen del Servidor'),
                ],
              ),
            ),
            actions: [
              if (option != null) ...[
                TextButton(
                  onPressed: () async {
                    await ref.read(seriesRepositoryProvider).deleteSeriesOption(option.id);
                    _loadOptions();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('ELIMINAR', style: TextStyle(color: Colors.redAccent)),
                ),
                const SizedBox(width: 20),
              ],
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR', style: TextStyle(color: Colors.white54))),
              ElevatedButton(
                onPressed: () async {
                  if (resController.text.isEmpty || urlController.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Por favor, rellena al menos la Resolución y la URL')));
                    return;
                  }
                  
                  try {
                    final newOption = SeriesOption(
                      id: option?.id ?? const Uuid().v4(),
                      seriesId: widget.series!.id,
                      resolution: resController.text,
                      videoUrl: urlController.text,
                      serverImagePath: imgController.text,
                      language: selectedLanguage,
                      extractionAlgorithm: selectedAlgorithm,
                    );
                    if (option == null) {
                      await ref.read(seriesRepositoryProvider).addSeriesOption(newOption);
                    } else {
                      await ref.read(seriesRepositoryProvider).updateSeriesOption(newOption);
                    }
                    _loadOptions();
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al guardar la opción: $e')));
                    }
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF), foregroundColor: Colors.white),
                child: const Text('GUARDAR'),
              ),
            ],
          );
        }
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
    
    // We reuse the SeriesScraperDialog logic but with a different focus
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

  void _fetchTmdbData() async {
    final id = _tmdbIdController.text;
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Introduce un TMDB ID primero')));
      return;
    }

    setState(() => _isScraping = true);
    final data = await TmdbService.getSeriesMetadata(id);
    
    if (data != null) {
      setState(() {
        _nameController.text = data['name'] ?? _nameController.text;
        _descriptionController.text = data['description'] ?? _descriptionController.text;
        _yearController.text = data['year'] ?? _yearController.text;
        _ratingController.text = data['rating']?.toString() ?? _ratingController.text;
        _imageController.text = data['image'] ?? _imageController.text;
        _backdropUrlController.text = data['backdrop'] ?? _backdropUrlController.text;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Metadatos cargados desde TMDB'), backgroundColor: Colors.green));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se encontró información para este ID'), backgroundColor: Colors.redAccent));
    }
    setState(() => _isScraping = false);
  }

  void _generateSmartLink() async {
    final id = _tmdbIdController.text.trim();
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Introduce un TMDB ID primero')));
      return;
    }

    final newOpt = SeriesOption(
      id: const Uuid().v4(),
      seriesId: widget.series!.id,
      serverImagePath: 'https://videasy.net/logo.png',
      resolution: '1080P',
      videoUrl: 'https://player.videasy.net/tv/$id', // Corrected base URL for TV shows
      language: 'Latino',
      extractionAlgorithm: 3,
    );
    await ref.read(seriesRepositoryProvider).addSeriesOption(newOpt);

    _loadOptions();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Servidor Videasy (Latino, 1080P) añadido.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Widget _buildTextField({required TextEditingController controller, required String labelText, int maxLines = 1, TextInputType? keyboardType}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(labelText, style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white.withOpacity(0.04),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: Text(
          widget.series == null ? 'NUEVA SERIE' : 'EDITAR SERIE',
          style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(context).padding.bottom + 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTextField(controller: _imageController, labelText: 'URL del Póster'),
            const SizedBox(height: 16),
            _buildTextField(controller: _backdropUrlController, labelText: 'URL de la Portada (Backdrop)'),
            const SizedBox(height: 16),
            _buildTextField(controller: _detailsUrlController, labelText: 'URL de Detalles (Para Scraping)'),
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
            const Text('CATEGORÍA', style: TextStyle(color: Color(0xFF00A3FF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            ref.watch(seriesCategoriesProvider).when(
              data: (categories) {
                return DropdownButtonFormField<String>(
                  dropdownColor: const Color(0xFF2C2C2C),
                  value: _selectedCategoryId,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.04),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
                  ),
                  items: [
                    const DropdownMenuItem<String>(value: null, child: Text('Sin Categoría')),
                    ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
                  ],
                  onChanged: (val) => setState(() => _selectedCategoryId = val),
                );
              },
              loading: () => const CircularProgressIndicator(),
              error: (e, s) => Text('Error cargando categorías: $e', style: const TextStyle(color: Colors.red)),
            ),
            const SizedBox(height: 16),
            _buildTextField(controller: _nameController, labelText: 'Nombre de la Serie'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildTextField(controller: _ratingController, labelText: 'Calificación (0-10)', keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                const SizedBox(width: 16),
                Expanded(child: _buildTextField(controller: _yearController, labelText: 'Año', keyboardType: TextInputType.number)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildTextField(controller: _tmdbIdController, labelText: 'TMDB ID')),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isScraping ? null : _fetchTmdbData,
                  icon: const Icon(Icons.auto_fix_high, color: Color(0xFF00A3FF)),
                  tooltip: 'Autocompletar desde TMDB',
                ),
                const SizedBox(width: 8),
                Expanded(child: _buildTextField(controller: _imdbIdController, labelText: 'IMDB ID')),
              ],
            ),
            const SizedBox(height: 16),
            _buildTextField(controller: _descriptionController, labelText: 'Descripción de la Serie', maxLines: 5),
            const SizedBox(height: 32),
            Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'SERVIDORES Y EXTRACCIÓN', 
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _generateSmartLink,
                    icon: const Icon(Icons.bolt, color: Colors.amber, size: 18),
                    label: const Text('ENLACE API', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (widget.series == null)
              const Text('Guarda la serie primero para agregar opciones y mapear temporadas.', style: TextStyle(color: Colors.white38))
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
                      title: Text('${_options[index].resolution} (${_options[index].language})', style: const TextStyle(color: Colors.white)),
                      subtitle: Text(_options[index].videoUrl, style: const TextStyle(color: Colors.white38, fontSize: 10), maxLines: 1),
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
              const SizedBox(height: 24),
              // Button to manage Seasons and Episodes
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFBC00FF), Color(0xFF00A3FF)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFFBC00FF).withOpacity(0.3), blurRadius: 10, offset: const Offset(-2, 0)),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AdminSeasonsEpisodesPage(series: widget.series!),
                      ),
                    );
                  },
                  icon: const Icon(Icons.auto_awesome, color: Colors.white),
                  label: const Text('MAPEADO DE TEMPORADAS Y CAPÍTULOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 48),
            Row(
              children: [
                if (widget.series != null) ...[
                  Expanded(
                    flex: 1,
                    child: OutlinedButton(
                      onPressed: _deleteSeries,
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
                      onPressed: _saveSeries,
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
