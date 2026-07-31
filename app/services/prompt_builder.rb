# Renderuje prompty sesji Claude z szablonów ERB w app/prompts/.
class PromptBuilder
  TEMPLATES_DIR = Rails.root.join("app", "prompts")
  # Wspólne zasady pisania (czytelność dla osoby z ADHD) — jedno źródło prawdy
  # dla wszystkich promptów. Każdy szablon wstawia je przez `<%= style %>`;
  # pilnuje tego test, bo prompt bez tych zasad wraca ze ścianą tekstu.
  STYLE_PATH = TEMPLATES_DIR.join("_style.md")

  def self.describe(review)
    render("describe", review)
  end

  def self.describe_task(review)
    render("describe_task", review)
  end

  def self.comment_task(review)
    render("comment_task", review)
  end

  def self.review(review)
    render("review", review)
  end

  # Weryfikacja poprawek idzie ZAWSZE świeżą sesją (nie ma czego wznawiać: pytanie
  # dotyczy kodu wypchniętego po decyzji), więc kontekst po przełączeniu konta
  # wymuszamy tak samo jak w followupie bez `--resume`.
  def self.verify_fixes(review)
    render("verify_fixes", review, force_context: true)
  end

  # Świeża sesja Z ZAŁOŻENIA (nie przez przypadek): cała wartość weryfikacji
  # zasadności bierze się z braku kontekstu sesji, która te uwagi wymyśliła.
  def self.verify_findings(review)
    render("verify_findings", review, force_context: true)
  end

  # `resumed` przychodzi z joba, bo tylko on wie, czy sesja faktycznie dostała
  # `--resume`. Świeża sesja nie zna poprzedniego przebiegu, więc kontekst musi
  # przyjechać w prompcie także wtedy, gdy konto się nie zmieniło, a plik sesji
  # po prostu zniknął (sprzątanie Claude CLI po ~30 dniach, usunięty worktree →
  # inny slug katalogu). Bez tego prompt obiecywałby sesji kontekst, którego nie ma,
  # a kazał nadpisać cały result.json — czyli skasować poprzednie znaleziska.
  def self.followup(review, message, resumed:)
    render("followup", review, force_context: !resumed, message: message, resumed: resumed)
  end

  # Bez cache'owania _style.md: prompt renderujemy kilka razy na review, a edycja
  # zasad ma działać bez restartu apki.
  def self.render(name, review, force_context: false, **extra)
    template = File.read(TEMPLATES_DIR.join("#{name}.md.erb"))
    ERB.new(template, trim_mode: "-")
       .result_with_hash(review: review, style: File.read(STYLE_PATH),
                         switched_context: switched_context(review, force: force_context), **extra)
  end
  private_class_method :render

  # Pusty string, dopóki review siedzi na tym samym koncie, a sesja niesie własną
  # historię. Po przełączeniu sekcja idzie do promptu nawet wtedy, gdy sesję udało
  # się skopiować i `--resume` zadziałał — kilka kB kosztu wobec ryzyka, że wznowiona
  # sesja nie zorientuje się w sytuacji.
  def self.switched_context(review, force: false)
    switched = review.switched_account?
    return "" unless force || switched

    ERB.new(File.read(TEMPLATES_DIR.join("_switched_context.md.erb")), trim_mode: "-")
       .result_with_hash(review: review, switched: switched)
  end
  private_class_method :switched_context
end
