@tool
class_name LightSpeedArtProfileArtAssetEntry
extends RefCounted

## 已导入美术资源的只读数据条目。
## 职责：描述一个可加载为 Texture2D 的美术资源，供 Catalog 与展示层消费。
## 输入输出：由 ArtAssetCatalog 在扫描时构造；字段只读语义，不提供修改入口。
## 副作用：无；不修改图片、不保存 Profile、不参与目录扫描。
## 边界：仅承载元数据与 Texture2D 引用，不做任何文件系统或资源写操作。

## 资源在 res:// 下的完整路径，例如 res://assets/art/crystals/crystal_normal_unlit.png。
var resource_path: String = ""

## 文件名（含扩展名），例如 crystal_normal_unlit.png。
var file_name: String = ""

## 相对美术根目录的子目录，根目录下为空串；例如 crystals 或 mechanisms/mirrors。
var relative_directory: String = ""

## 小写扩展名，例如 png。
var extension: String = ""

## 已加载纹理的像素尺寸；加载失败或未知时为 Vector2i.ZERO。
var texture_size: Vector2i = Vector2i.ZERO

## 已加载的 Texture2D 引用；扫描成功时必为 Texture2D。
var texture: Texture2D = null
