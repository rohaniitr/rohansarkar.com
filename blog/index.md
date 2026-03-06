---
layout: default
title: Blog
description: Technical writing on mobile architecture, fintech systems, and engineering practices.
permalink: /blog/
---

# Blog

Technical writing on mobile architecture, fintech systems, and engineering practices.

---

## Posts

{% assign sorted_posts = site.posts | sort: "date" | reverse %}
{% for post in sorted_posts %}
### [{{ post.title }}]({{ post.url }})
*{{ post.date | date: "%B %d, %Y" }}*

{% if post.excerpt %}
{{ post.excerpt | strip_html }}
{% else %}
{{ post.content | strip_html | truncate: 200 }}
{% endif %}

[Read more →]({{ post.url }})

---
{% endfor %}

{% if site.posts.size == 0 %}
*No posts yet.*
{% endif %}
