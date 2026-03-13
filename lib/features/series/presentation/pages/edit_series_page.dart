import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../providers.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/series_option.dart';
import '../providers/series_provider.dart';
import '../providers/series_category_provider.dart';
import 'admin_seasons_episodes_page.dart';

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
  String? _selectedCategoryId;
  List<SeriesOption> _options = [];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.series?.name ?? '');
    _imageController = TextEditingController(text: widget.series?.imagePath ?? '');
    _detailsUrlController = TextEditingController(text: widget.series?.detailsUrl ?? '');
    _backdropUrlController = TextEditingController(text: widget.series?.backdropUrl ?? '');
    _descriptionController = TextEditingController(text: widget.series?.description ?? '');
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
        createdAt: DateTime.now(),
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
        rating: widget.series!.rating,
        year: widget.series!.year,
        backdrop: widget.series!.backdrop,
        createdAt: widget.series!.createdAt,
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
                  _buildTextField(controller: resController, labelText: 'Resolución (ej: 1080p, Auto)'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
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
                      DropdownMenuItem(value: 'Subtitulado', child: Text('Subtitulado', style: TextStyle(color: Colors.white))),
                    ],
                    onChanged: (val) {
                      setState(() {
                        selectedLanguage = val;
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
                  if (resController.text.isNotEmpty && urlController.text.isNotEmpty) {
                    final newOption = SeriesOption(
                      id: option?.id ?? const Uuid().v4(),
                      seriesId: widget.series!.id,
                      resolution: resController.text,
                      videoUrl: urlController.text,
                      serverImagePath: imgController.text,
                      language: selectedLanguage,
                    );
                    if (option == null) {
                      await ref.read(seriesRepositoryProvider).addSeriesOption(newOption);
                    } else {
                      await ref.read(seriesRepositoryProvider).updateSeriesOption(newOption);
                    }
                    _loadOptions();
                    if (context.mounted) Navigator.pop(context);
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

  Widget _buildTextField({required TextEditingController controller, required String labelText, int maxLines = 1}) {
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
            const SizedBox(height: 16),
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
            _buildTextField(controller: _descriptionController, labelText: 'Descripción de la Serie', maxLines: 3),
            const SizedBox(height: 32),
            const Text('OPCIONES DE SERVIDORES Y EXTRACCIÓN', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
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
