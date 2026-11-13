%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          # A module is documented where its name and specs leave something unsaid,
          # not by rule.
          {Credo.Check.Readability.ModuleDoc, []}
        ]
      }
    }
  ]
}
