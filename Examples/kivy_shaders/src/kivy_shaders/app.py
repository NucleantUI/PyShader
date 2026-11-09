"""The gallery: a shader per tab, drawn by Kivy from the `.glsl` files the
build backend compiled from the PyShader modules in `shaders/`.

Each shader is a `RenderContext` whose `shader.source` is one of those files.
The app sets the uniforms the shaders take: `time`, `resolution` (the
widget's size in pixels), `mouse` (y-up, in the widget) and, for the ripple,
its `strength` argument.
"""

from __future__ import annotations

import os
from importlib.resources import files

from kivy import kivy_data_dir
from kivy.app import App
from kivy.clock import Clock
from kivy.core.image import Image as CoreImage
from kivy.graphics import Rectangle, RenderContext
from kivy.lang import Builder
from kivy.properties import NumericProperty, StringProperty
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.widget import Widget

SHADERS = files("kivy_shaders") / "shaders"


class ShaderView(Widget):
    """A rectangle filled by one compiled PyShader shader."""

    shader = StringProperty("")
    strength = NumericProperty(0.006)
    #: An image the shader reads through layer(); none for the generative ones.
    texture_file = StringProperty("")

    def __init__(self, **kwargs):
        self.canvas = RenderContext(use_parent_projection=True, use_parent_modelview=True, use_parent_frag_modelview=True)
        with self.canvas:
            self.rect = Rectangle(pos=self.pos, size=self.size)
        super().__init__(**kwargs)
        self.mouse = (0.0, 0.0)
        self.bind(pos=self._layout, size=self._layout, shader=self._load, texture_file=self._load_texture)
        self._load()
        self._load_texture()
        Clock.schedule_interval(self._tick, 0)

    def _load(self, *_):
        if not self.shader:
            return
        program = self.canvas.shader
        program.source = str(SHADERS / self.shader)
        if not program.success:
            raise RuntimeError(f"Kivy could not compile {self.shader}; see the log above")

    def _load_texture(self, *_):
        self.rect.texture = CoreImage(self.texture_file).texture if self.texture_file else None

    def _layout(self, *_):
        self.rect.pos = self.pos
        self.rect.size = self.size
        self.mouse = (self.width / 2, self.height / 2)

    def _tick(self, _dt):
        self.canvas["time"] = Clock.get_boottime()
        self.canvas["resolution"] = [float(self.width), float(self.height)]
        self.canvas["mouse"] = [float(self.mouse[0]), float(self.mouse[1])]
        self.canvas["strength"] = float(self.strength)

    def on_touch_down(self, touch):
        return self.on_touch_move(touch)

    def on_touch_move(self, touch):
        if not self.collide_point(*touch.pos):
            return False
        self.mouse = (touch.x - self.x, touch.y - self.y)
        return True


KV = """
#:import os os
<Gallery>:
    orientation: "vertical"
    BoxLayout:
        size_hint_y: None
        height: "44dp"
        spacing: "4dp"
        padding: "4dp"
        ToggleButton:
            text: "Plasma (fragment)"
            group: "shader"
            state: "down"
            on_press: root.show("plasma.glsl", "")
        ToggleButton:
            text: "Aurora (compute)"
            group: "shader"
            on_press: root.show("aurora.glsl", "")
        ToggleButton:
            text: "Ripple (layer + argument)"
            group: "shader"
            on_press: root.show("ripple.glsl", root.image)
    ShaderView:
        id: view
        shader: "plasma.glsl"
    BoxLayout:
        size_hint_y: None
        height: "44dp" if view.shader == "ripple.glsl" else 0
        opacity: 1 if view.shader == "ripple.glsl" else 0
        padding: "8dp", 0
        Label:
            text: "strength {:.3f}".format(slider.value)
            size_hint_x: None
            width: "120dp"
        Slider:
            id: slider
            min: 0.0
            max: 0.02
            value: view.strength
            on_value: view.strength = self.value
"""


class Gallery(BoxLayout):
    #: Kivy's own logo, as the image the ripple bends.
    image = StringProperty(os.path.join(kivy_data_dir, "logo", "kivy-icon-512.png"))

    def show(self, shader: str, texture_file: str) -> None:
        view = self.ids.view
        view.texture_file = texture_file
        view.shader = shader


class ShaderGalleryApp(App):
    title = "PyShader on Kivy"

    def build(self):
        Builder.load_string(KV)
        return Gallery()


def main() -> None:
    ShaderGalleryApp().run()


if __name__ == "__main__":
    main()
