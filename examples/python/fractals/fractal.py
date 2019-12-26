#!/usr/bin/python
"""Creates a fractal image"""

from PIL import Image, ImageDraw
import colorsys
import sys


def create_palette(colors_max):
    """Calculate a tolerable palette"""
    palette = [0] * colors_max
    for i in range(colors_max):
        f = 1-abs((float(i)/colors_max-1)**15)
        r, g, b = colorsys.hsv_to_rgb(.66+f/3, 1-f/2, f)
        palette[i] = (int(r*255), int(g*255), int(b*255))
    return palette

def iterate_mandelbrot(iterate_max, c, z = 0):
    """Calculate the mandelbrot sequence for the point c with start value z"""
    for n in range(iterate_max + 1):
        z = z * z + c
        if abs(z) > 2:
            return n
    return None

def create_fractal(data):
    """Create our fractal"""

    dimensions = (data["dimensions"]["x"], data["dimensions"]["y"])
    scale = 1.0/(dimensions[0]/3)
    center = (data["center_mandlebrot"]["x"], data["center_mandlebrot"]["y"])       # Use this for Mandelbrot set
    #center = (1.5, 1.5)       # Use this for Julia set
    iterate_max = data["iterate_max"]
    colors_max = data["colors_max"]

    img = Image.new("RGB", dimensions)
    drawing = ImageDraw.Draw(img)
    palette = create_palette(colors_max)

    # Draw our image
    for y in range(dimensions[1]):
        for x in range(dimensions[0]):
            c = complex(x * scale - center[0], y * scale - center[1])

            n = iterate_mandelbrot(iterate_max, c)            # Use this for Mandelbrot set
            #n = iterate_mandelbrot(complex(0.3, 0.6), c)  # Use this for Julia set

            if n is None:
                v = 1
            else:
                v = n/100.0

            drawing.point((x, y), fill = palette[int(v * (colors_max-1))])

    del drawing
    return img

if __name__ == "__main__":
    data = {
        "dimensions": {"x": 800, "y": 800},
        "iterate_max": 100,
        "colors_max": 50,
        "center_mandlebrot": {"x": 2.2, "y": 1.5},
        "center_julia": {"x": 1.5, "y": 1.5},
    }

    img = create_fractal(data)
    img.save(sys.argv[1])

